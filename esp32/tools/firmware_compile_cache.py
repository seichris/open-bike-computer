"""Track macro-included UI configuration while keeping identity metadata scoped."""

import json
import os
import re
import shlex
import struct
import tempfile
from collections.abc import Iterable
from pathlib import Path


FORCE_INCLUDE_OPTIONS = ("-include", "-imacros")


# Libraries compiled without C++ exception support. Arduino_GFX neither throws
# nor catches, yet the Arduino framework's CXXFLAGS carry -fexceptions into
# every C++ translation unit, so its unwind tables (.eh_frame and
# .gcc_except_table) only cost flash. An allocation failure inside such a
# library terminates, as an uncaught exception did before. Matched against a
# directory component of the source path under the dependency store.
NO_EXCEPTION_LIBRARIES = frozenset({"GFX Library for Arduino"})

# Libraries that keep GCC's stack-smashing protector (-fstack-protector, the
# Arduino default): everything that parses input from outside the device. The
# map, firmware and device transfers and the HTTPS handlers, the BLE service
# and the NimBLE host, the GPX/XML, NMEA and map-block parsers, and the Arduino
# network glue. Every other application object, the Arduino core and the
# remaining libraries are compiled with -fno-stack-protector: their functions
# only ever see data the firmware produced itself, and the canary cost them
# flash without guarding an input path. The IDF components are not built here;
# they keep the protector through CONFIG_COMPILER_STACK_CHECK_MODE. Matched
# against a directory component of the source path, like the set above.
STACK_PROTECTED_LIBRARIES = frozenset({
    "map_transfer",
    "map_transfer_http",
    "device_transfer",
    "firmware_update",
    "ride_diagnostics",
    "ble_navigation",
    "NimBLE-Arduino",
    "gpx",
    "tinyxml2",
    "gps",
    "maps",
    "Network",
    "WiFi",
})

STACK_PROTECTOR_FLAGS = ("-fstack-protector", "-fstack-protector-strong", "-fstack-protector-all")
COMPILED_SUFFIXES = (".c", ".cc", ".cpp", ".cxx")

# PlatformIO builds each library below .pio/build/<env>/lib<hash>/<name>/.
_BUILD_LIBRARY_DIR = re.compile(r"^lib[0-9a-f]{3}$")


def library_name(parts) -> str | None:
    """The library a path belongs to, from its directory under a library root.

    Accepts a source path relative to the project (`lib/<name>/…`, the
    dependency store's `…/libdeps/<env>/<name>/…`, the framework's
    `…/libraries/<name>/…`) or an object path relative to the build directory
    (`lib<hash>/<name>/…`, or the mirrored framework `…/libraries/<name>/…`).
    Project sources and the Arduino core belong to no library. Only the
    component directly under the root counts, so a checkout living under a
    directory that happens to carry a library's name can never match.
    """
    parts = tuple(parts)
    for index, part in enumerate(parts[:-1]):
        if index == 0 and part == "lib":
            return parts[1]
        if _BUILD_LIBRARY_DIR.match(part) or part == "libraries":
            return parts[index + 1]
        if part == "libdeps" and index + 2 < len(parts):
            return parts[index + 2]
    return None


def source_library(source: Path, project: Path) -> str | None:
    """`library_name` for an absolute source path below `project`."""
    try:
        parts = source.relative_to(project).parts
    except ValueError:
        parts = source.parts
    return library_name(parts)


def _flag_list(build_env, variable: str) -> list:
    flags = build_env.get(variable)
    if isinstance(flags, str):
        flags = shlex.split(flags)
    return list(flags) if isinstance(flags, Iterable) else []


def object_overrides(build_env, source: Path, project: Path) -> dict:
    """Per-object construction variable overrides for `source` below `project`."""
    if source.suffix.lower() not in COMPILED_SUFFIXES:
        return {}
    library = source_library(source, project)
    no_exceptions = source.suffix == ".cpp" and library in NO_EXCEPTION_LIBRARIES
    no_stack_protector = library not in STACK_PROTECTED_LIBRARIES
    if not no_exceptions and not no_stack_protector:
        return {}
    # SCons expands $CXXFLAGS before $CCFLAGS and GCC honours the last switch,
    # so the framework's switches are removed from both lists and the
    # overrides go last. A switch arriving through a response file cannot be
    # rewritten here; the post-build checks inspect the built objects instead.
    dropped = set()
    appended = []
    if no_exceptions:
        dropped.add("-fexceptions")
        appended.append("-fno-exceptions")
    if no_stack_protector:
        dropped.update(STACK_PROTECTOR_FLAGS)
        appended.append("-fno-stack-protector")
    cxxflags = [flag for flag in _flag_list(build_env, "CXXFLAGS") if flag not in dropped]
    ccflags = [flag for flag in _flag_list(build_env, "CCFLAGS") if flag not in dropped]
    return {"CXXFLAGS": cxxflags, "CCFLAGS": ccflags + appended}


# Section names GCC emits only for code built with exception support.
EXCEPTION_SECTIONS = (".eh_frame", ".gcc_except_table")


def _elf_section_headers(data: bytes, path: Path) -> list[tuple]:
    """Section headers of a 32-bit little-endian ELF object (the Xtensa format)."""
    if len(data) < 52 or data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        raise ValueError(f"not a 32-bit little-endian ELF object: {path}")
    (section_offset,) = struct.unpack_from("<I", data, 32)
    entry_size, count, names_index = struct.unpack_from("<HHH", data, 46)
    if (
        entry_size < 40
        or count == 0
        or names_index >= count
        or section_offset + entry_size * count > len(data)
    ):
        raise ValueError(f"malformed ELF section table: {path}")
    return [
        struct.unpack_from("<IIIIIIIIII", data, section_offset + index * entry_size)
        for index in range(count)
    ]


def _elf_string(table: bytes, offset: int, path: Path) -> str:
    end = table.find(b"\0", offset)
    if offset > len(table) or end < 0:
        raise ValueError(f"malformed ELF string table: {path}")
    return table[offset:end].decode("ascii", "replace")


def _elf_section_bytes(data: bytes, header: tuple, path: Path) -> bytes:
    start, size = header[4], header[5]
    if start + size > len(data):
        raise ValueError(f"malformed ELF section bounds: {path}")
    return data[start:start + size]


def elf_section_names(path: Path) -> list[str]:
    """Section names of a 32-bit little-endian ELF object (the Xtensa format)."""
    data = path.read_bytes()
    headers = _elf_section_headers(data, path)
    (_, _, names_index) = struct.unpack_from("<HHH", data, 46)
    strings = _elf_section_bytes(data, headers[names_index], path)
    return [_elf_string(strings, header[0], path) for header in headers]


def elf_undefined_symbols(path: Path) -> frozenset[str]:
    """Names of the undefined symbols an ELF32 object imports."""
    data = path.read_bytes()
    headers = _elf_section_headers(data, path)
    names = set()
    for header in headers:
        if header[1] != 2:  # SHT_SYMTAB
            continue
        link, entry_size = header[6], header[9]
        if entry_size != 16 or link >= len(headers):
            raise ValueError(f"malformed ELF symbol table: {path}")
        symbols = _elf_section_bytes(data, header, path)
        strings = _elf_section_bytes(data, headers[link], path)
        for offset in range(0, len(symbols) - len(symbols) % 16, 16):
            name_offset, _, _, _, _, section_index = struct.unpack_from("<IIIBBH", symbols, offset)
            if section_index == 0 and name_offset:  # SHN_UNDEF
                names.add(_elf_string(strings, name_offset, path))
    return frozenset(names)


def _carries_exception_tables(names: Iterable[str]) -> bool:
    return any(
        name == section or name.startswith(section + ".")
        for name in names
        for section in EXCEPTION_SECTIONS
    )


def verify_no_exception_objects(build_dir: Path, libraries: Iterable[str] = NO_EXCEPTION_LIBRARIES) -> int:
    """Prove the no-exception override reached every object it targets.

    Returns the number of objects inspected under `build_dir` (PlatformIO's
    .pio/build/<environment>). Raises RuntimeError when no object of a listed
    library exists, because the override then matched nothing (for example the
    library resolved under another directory name), or when an object still
    carries .eh_frame or .gcc_except_table sections, which means -fexceptions
    reached the compiler through a path the override does not rewrite.
    """
    libraries = frozenset(libraries)
    inspected = 0
    offenders = []
    for library in sorted(libraries):
        for path in sorted(build_dir.glob(f"lib*/{library}/**/*.o")):
            if _carries_exception_tables(elf_section_names(path)):
                offenders.append(str(path.relative_to(build_dir)))
            inspected += 1
    if inspected == 0:
        raise RuntimeError(
            "no objects of the no-exception libraries ("
            + ", ".join(sorted(libraries))
            + f") were built under {build_dir}"
        )
    if offenders:
        raise RuntimeError(
            "objects still carry exception tables: " + ", ".join(offenders)
        )
    return inspected


# Symbols a translation unit imports only when the protector instrumented it.
STACK_PROTECTOR_SYMBOLS = frozenset({"__stack_chk_fail", "__stack_chk_guard"})


def verify_stack_protector_scope(build_dir: Path, protected: Iterable[str] = STACK_PROTECTED_LIBRARIES) -> dict:
    """Prove the stack protector stayed exactly on the protected libraries.

    Walks every object PlatformIO built under `build_dir` (project sources,
    the Arduino core and all libraries). An object outside the protected set
    must not import the canary symbols, which proves -fno-stack-protector
    reached it. Each protected library must be present and at least one of its
    objects must import them, which proves the protector is still on where
    input from outside the device is parsed; a protected library whose last
    stack buffer disappears therefore fails the build until the list is
    revisited. Returns the counts for the build log.
    """
    protected = frozenset(protected)
    guarded_by_library = {library: 0 for library in protected}
    objects_by_library = {library: 0 for library in protected}
    offenders = []
    unprotected = 0
    for path in sorted(build_dir.rglob("*.o")):
        name = library_name(path.relative_to(build_dir).parts)
        library = name if name in protected else None
        guarded = not STACK_PROTECTOR_SYMBOLS.isdisjoint(elf_undefined_symbols(path))
        if library is None:
            unprotected += 1
            if guarded:
                offenders.append(str(path.relative_to(build_dir)))
        else:
            objects_by_library[library] += 1
            guarded_by_library[library] += int(guarded)
    missing = sorted(library for library, count in objects_by_library.items() if count == 0)
    if missing:
        raise RuntimeError(
            "protected libraries without any built object: " + ", ".join(missing)
        )
    unguarded = sorted(library for library, count in guarded_by_library.items() if count == 0)
    if unguarded:
        raise RuntimeError(
            "protected libraries whose objects no longer import the stack canary: "
            + ", ".join(unguarded)
        )
    if offenders:
        raise RuntimeError(
            "objects outside the protected libraries still use the stack protector: "
            + ", ".join(offenders)
        )
    return {
        "protectedLibraries": len(protected),
        "protectedObjects": sum(objects_by_library.values()),
        "guardedObjects": sum(guarded_by_library.values()),
        "unprotectedObjects": unprotected,
    }


def force_included_files(build_env, project: Path) -> list[str]:
    """Existing files named by -include/-imacros in this environment's flags.

    SCons' C scanner never reads compiler flags, so these headers are absent
    from dependency and cache signatures unless declared. PlatformIO stores a
    build flag as a ("-include", "relative/path") pair; flags appended directly
    are separate strings. Relative paths resolve from the project directory,
    where the compiler runs. Only existing files are returned, because SCons
    fails a build that depends on a missing file.
    """
    named = []
    for variable in ("CCFLAGS", "CFLAGS", "CXXFLAGS"):
        flags = build_env.get(variable)
        if isinstance(flags, str):
            flags = shlex.split(flags)
        if not isinstance(flags, Iterable):
            continue
        pending = False
        for flag in flags:
            if isinstance(flag, (tuple, list)):
                if len(flag) == 2 and str(flag[0]) in FORCE_INCLUDE_OPTIONS:
                    named.append(flag[1])
                pending = False
                continue
            text = str(flag)
            if pending:
                named.append(flag)
                pending = False
            elif text in FORCE_INCLUDE_OPTIONS:
                pending = True
            else:
                named.extend(text[len(option):] for option in FORCE_INCLUDE_OPTIONS
                             if text.startswith(option) and len(text) > len(option))
    files = []
    for value in named:
        path = Path(value.get_abspath() if hasattr(value, "get_abspath") else build_env.subst(str(value)))
        path = path if path.is_absolute() else project / path
        if path.is_file():
            files.append(str(path.resolve()))
    return files


def configure_metadata_identity(env, git_sha: str, timestamp: str) -> None:
    project = Path(env.subst("$PROJECT_DIR")).resolve()
    profile = env.subst("$PIOENV")
    directory = project / ".pio/open-bike-build/build-identity" / profile
    current = project
    for part in directory.relative_to(project).parts:
        current /= part
        if current.is_symlink() or (current.exists() and not current.is_dir()):
            raise RuntimeError("unsafe firmware identity directory")
        current.mkdir(exist_ok=True)
    header = directory / "firmware_identity.h"
    identity = (
        "// Generated by the verified firmware build.\n"
        f"#define GIT_SHA {json.dumps(git_sha)}\n"
        f"#define BUILD_TIMESTAMP {json.dumps(timestamp)}\n"
    )
    clock = directory / "firmware_compile_clock.h"
    # Arduino's chip report uses these macros even with IDF compile-date
    # descriptors disabled. Make their values explicit compiler inputs rather
    # than inheriting SOURCE_DATE_EPOCH, which SCons does not fingerprint.
    clock_contents = '''// Generated compiler clock; source time lives in firmware_metadata.
#ifndef OPEN_BIKE_FIRMWARE_COMPILE_CLOCK_H
#define OPEN_BIKE_FIRMWARE_COMPILE_CLOCK_H
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wbuiltin-macro-redefined"
#undef __DATE__
#undef __TIME__
#undef __TIMESTAMP__
#define __DATE__ "Jan  1 1970"
#define __TIME__ "00:00:00"
#define __TIMESTAMP__ "Thu Jan  1 00:00:00 1970"
#pragma GCC diagnostic pop
#endif
'''
    for generated, contents in ((header, identity), (clock, clock_contents)):
        if generated.is_symlink() or (generated.exists() and (not generated.is_file() or generated.stat().st_nlink != 1)):
            raise RuntimeError("unsafe firmware identity header")
        if not generated.exists() or generated.read_text() != contents:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=directory, delete=False) as stream:
                stream.write(contents)
                temporary = Path(stream.name)
            try:
                os.replace(temporary, generated)
            finally:
                temporary.unlink(missing_ok=True)

    env.Append(CCFLAGS=[
        "-Werror=date-time",
        "-include", str(clock),
        f"-ffile-prefix-map={project}=/open-bike-computer/esp32",
    ])

    # LVGL includes LV_CONF_PATH through a stringifying macro. SCons' include
    # scanner cannot discover that edge reliably, so a warm object cache can
    # otherwise retain the old allocator size (and other ABI/config settings).
    # Every application/library object must see this input, including local
    # consumers of LVGL headers. The separately attested framework core is not
    # built through this application middleware.
    compile_inputs = [str(clock), str(project / "lib/lvgl/lv_conf.h")]

    def inputs_for(build_env):
        # Force-included headers (for example the NimBLE connection limit) are
        # equally invisible to the scanner, so they are declared as well.
        return list(dict.fromkeys(compile_inputs + force_included_files(build_env, project)))

    def metadata_object(build_env, node):
        source = Path(node.srcnode().get_abspath())
        if source != project / "lib/firmware_metadata/firmware_metadata.cpp":
            result = build_env.Object(node, **object_overrides(build_env, source, project))
            build_env.Depends(result, inputs_for(build_env))
            return result[0]
        identity_env = build_env.Clone()
        identity_env.Append(CCFLAGS=["-include", str(header)])
        result = identity_env.Object(node, **object_overrides(identity_env, source, project))
        identity_env.Depends(result, inputs_for(identity_env))
        identity_env.Depends(result, str(header))
        return result[0]

    env.AddBuildMiddleware(metadata_object)


def relocate_core_text(root: Path, source_project: Path, project: Path) -> int:
    """Rebase UTF-8 launchers/configuration; compiled binary inputs stay exact.

    Archive extraction already rebases absolute symlinks. The caller verifies
    the complete transport archive before extraction and attests the derived
    local tree before executing anything from it.
    """
    old = os.fsencode(str(source_project))
    new = os.fsencode(str(project))
    old_uri = source_project.as_uri().encode("utf-8")
    new_uri = project.as_uri().encode("utf-8")

    def rebase(contents):
        # Pinned PlatformIO file:// locations are raw filesystem paths. When
        # the origin has no escaped characters its URI is indistinguishable
        # from that raw form, so preserve raw paths in the receiving metadata.
        if old_uri == b"file://" + old:
            return contents.replace(old, new)
        # Preserve explicitly percent-encoded URLs from other configuration.
        return contents.replace(old_uri, new_uri).replace(old, new)
    changed = 0
    for directory, _, files in os.walk(root, followlinks=False):
        for name in files:
            path = Path(directory) / name
            if path.is_symlink():
                continue
            data = path.read_bytes()
            if (old not in data and old_uri not in data) or b"\x00" in data:
                continue
            try:
                data.decode("utf-8")
            except UnicodeDecodeError:
                continue
            relocated = rebase(data)
            if data.startswith(b"#!" + old):
                # A launcher created in a path without spaces may be restored
                # into a path with spaces. The kernel cannot parse that Python
                # shebang; use the standard shell/Python exec trampoline.
                first, _, body = data.partition(b"\n")
                command = shlex.split(first[2:].decode("utf-8"))
                if command and "python" in Path(command[0]).name:
                    command = [argument.replace(str(source_project), str(project)) for argument in command]
                    quoted = " ".join(shlex.quote(argument) for argument in command)
                    relocated = (
                        "#!/bin/sh\n'''exec' " + quoted + ' "$0" "$@"\n' + "' '''\n"
                    ).encode("utf-8") + rebase(body)
            elif data.startswith(b"#!/bin/sh\n'''exec' "):
                lines = data.split(b"\n", 3)
                if len(lines) == 4 and lines[2] == b"' '''":
                    arguments = shlex.split(lines[1].decode("utf-8"))
                    if arguments[0] == "exec" and arguments[-2:] == ["$0", "$@"]:
                        command = [argument.replace(str(source_project), str(project)) for argument in arguments[1:-2]]
                        quoted = " ".join(shlex.quote(argument) for argument in command)
                        relocated = (
                            "#!/bin/sh\n'''exec' " + quoted + ' "$0" "$@"\n' + "' '''\n"
                        ).encode("utf-8") + rebase(lines[3])
            path.write_bytes(relocated)
            changed += 1
    return changed
