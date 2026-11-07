#!/usr/bin/env python3
"""Keep every include resolvable the way PlatformIO compiles each library.

PlatformIO's library dependency finder (``lib_ldf_mode = deep``) compiles a
library with its own include directories, the complete include-path set of
each library it depends on directly, the own directories of a dependency that
closes a cycle, and the ``-I`` directories of the shared build flags. It
discovers dependencies by scanning the library's own source files (plus the
headers of the same library they pull in) with each file's includes taken in
SCons' order: the include token with its quote characters, compared as text,
so quoted names precede angled ones and upper case precedes lower case.
Headers of other libraries are not scanned on the including library's behalf
and a header-only library carries nothing. A header of library B that includes
a header of library C by bare name therefore compiles inside library A only
while some non-circular dependency of A happens to carry C's directory, and an
unrelated include change elsewhere can remove that route. Removing
``lib/upgrade`` lost ``WiFi.h`` for ``lib/lvgl`` (#766), and merging main into
#442 lost ``storage.hpp`` for ``lib/epaper_display``; the ``-fsyntax-only``
cross-check cannot see either because it adds every include directory.

This test replays those rules (PlatformIO 6.1.18, ``builder/tools/piolib.py``
and ``fs.match_src_files``; SCons 4.8.1 ``Scanner/C.py``) over ``esp32/lib``
and ``esp32/src`` and fails on any include that one of the libraries could not
resolve. The Arduino framework libraries and the ``lib_deps`` packages live
outside the repository; ``ldf_external_libraries.json`` beside this file
records, from the locked runtime's package store, each one's headers and the
other external libraries whose directories its compile receives, so a
repository library that reaches ``WiFi.h`` only through another library's
header is reported the same way. The data is tied to the runtime lock and is
regenerated with ``--update-externals STORE_DIR`` (a
``.pio/open-bike-build/platformio/<env>`` directory of a finished build).
Externals never include repository headers, so they are not scanned on this
tree. Run ``--list`` to print each library's dependencies, or ``--root DIR``
to check another ``esp32`` tree (it needs that tree's ``platformio.ini`` for
the ``-I`` build flags).
"""
from __future__ import annotations

import argparse
import configparser
import glob
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile
import unittest

EXTERNALS_FILE = pathlib.Path(__file__).with_name("ldf_external_libraries.json")
RUNTIME_LOCK = pathlib.Path("tools/firmware-runtime/lock-v1.json")

HEADER_EXT = ["h", "hpp"]
ASM_EXT = ["S", "spp", "SPP", "sx", "s", "asm", "ASM"]
SOURCE_EXT = ["c", "cc", "cpp", "cxx", "c++"] + ASM_EXT
PROJECT_SRC_FILTER = ["+<*>", "-<.git/>", "-<.svn/>"]
LIBRARY_SRC_FILTER = PROJECT_SRC_FILTER + ["-<example/>", "-<examples/>", "-<test/>", "-<tests/>"]
# SCons.Scanner.C.CScanner: the three groups form the include token SCons sorts by.
INCLUDE = re.compile(r'^[ \t]*#[ \t]*(?:include|import)[ \t]*(<|")([^>"]+)(>|")', re.M)
ARDUINO_INCLUDE = re.compile(r'^#include\s+(<|")(Arduino|mbed)\.h(<|")', re.M)


def match_src_files(src_dir: pathlib.Path, src_filter: list[str], extensions: list[str]) -> list[pathlib.Path]:
    """platformio.fs.match_src_files: glob each pattern, walk matched directories, union/difference in order."""
    result: set[str] = set()
    if isinstance(src_filter, (list, tuple)):
        src_filter = " ".join(src_filter)
    for action, pattern in re.findall(r"(\+|\-)<([^>]+)>", src_filter):
        candidates: set[str] = set()
        for item in glob.glob(os.path.join(glob.escape(str(src_dir)), pattern), recursive=True):
            paths = [item] if not os.path.isdir(item) else [
                os.path.join(root, name) for root, _, files in os.walk(item, followlinks=True) for name in files]
            for path in paths:
                if any(path.endswith("." + ext) for ext in extensions):
                    candidates.add(os.path.relpath(path, src_dir))
        result = result | candidates if action == "+" else result - candidates
    return [src_dir / item for item in sorted(result)]


class Library:
    """One PlatformIO library builder: a directory under lib/, or the project."""

    def __init__(self, path: pathlib.Path, name: str, src_dir: pathlib.Path,
                 include_dirs: list[pathlib.Path], src_filter: "list[str] | str"):
        self.path, self.name, self.src_dir, self.src_filter = path, name, src_dir, src_filter
        self._include_dirs = include_dirs
        self.depbuilders: list[Library] = []
        self.circular: list[Library] = []
        self.processed: set[pathlib.Path] = set()
        self.scanned = False

    @classmethod
    def from_dir(cls, path: pathlib.Path) -> "Library | None":
        """LibBuilderFactory.new: manifest, Arduino-style or unknown library; None for an unreadable manifest."""
        manifest_path = path / "library.json"
        if manifest_path.is_file():
            try:
                build = json.loads(manifest_path.read_text()).get("build", {})
            except (ValueError, OSError):
                return None  # GetLibBuilders skips a library whose manifest fails to load
            src_dir = path / build["srcDir"] if build.get("srcDir") else cls._subdir(path, "src")
            include = [path / build["includeDir"]] if build.get("includeDir") else cls._optional(path, "include")
            flags = build.get("flags", [])
            extra = [path / token for flag in (flags if isinstance(flags, list) else [flags])
                     for token in re.findall(r"-I\s*(\S+)", flag)]
            return cls(path, path.name, src_dir, include + [src_dir] + extra, build.get("srcFilter") or LIBRARY_SRC_FILTER)
        src_dir = cls._subdir(path, "src")
        if cls._is_arduino(path) and not (path / "src").is_dir():
            # ArduinoLibBuilder without src/: top-level sources and utility/ only.
            src_filter = []
            for ext in SOURCE_EXT + HEADER_EXT:
                if ext.lower() == "asm":
                    continue
                src_filter.append(f"+<*.{ext}>")
                if (path / "utility").is_dir():
                    src_filter.append(f"+<utility/*.{ext}>")
            # ArduinoLibBuilder reports include/ only beside src/; utility/ joins the include dirs here.
            include = [src_dir] + ([path / "utility"] if (path / "utility").is_dir() else [])
            return cls(path, path.name, src_dir, include, src_filter)
        return cls(path, path.name, src_dir, cls._optional(path, "include") + [src_dir], LIBRARY_SRC_FILTER)

    @staticmethod
    def _subdir(path: pathlib.Path, name: str) -> pathlib.Path:
        for candidate in (name, name.capitalize()):
            if (path / candidate).is_dir():
                return path / candidate
        return path

    @staticmethod
    def _optional(path: pathlib.Path, name: str) -> list[pathlib.Path]:
        found = Library._subdir(path, name)
        return [found] if found != path else []

    @staticmethod
    def _is_arduino(path: pathlib.Path) -> bool:
        if any((path / name).is_file() for name in ("library.properties", "keywords.txt")):
            return True
        for file in path.rglob("*"):
            if file.is_file() and any(file.name.endswith("." + ext) for ext in SOURCE_EXT + HEADER_EXT):
                text = file.read_text(encoding="utf8", errors="ignore")
                if "Arduino.h" in text and ARDUINO_INCLUDE.search(text):
                    return True
        return False

    def include_dirs(self) -> list[pathlib.Path]:
        return list(self._include_dirs)

    def contains(self, file: pathlib.Path) -> bool:
        return file == self.path or self.path in file.parents

    def search_files(self) -> list[pathlib.Path]:
        """The library's own source files, the only files its scan starts from."""
        return match_src_files(self.src_dir, self.src_filter, SOURCE_EXT)


class ExternalLibrary(Library):
    """A framework library or lib_deps package known only from the generated data."""

    def __init__(self, name: str, kind: str, headers: list[str]):
        virtual = pathlib.Path("<external>") / name
        super().__init__(virtual, name, virtual, [virtual], [])
        self.kind, self.headers = kind, set(headers)

    def search_files(self) -> list[pathlib.Path]:
        return []

    def describe(self) -> str:
        return f"the {self.name} {'framework' if self.kind == 'framework' else 'lib_deps'} library"


def load_externals(data: dict) -> list[ExternalLibrary]:
    libraries = {name: ExternalLibrary(name, entry["kind"], entry["headers"]) for name, entry in data["libraries"].items()}
    for name, entry in data["libraries"].items():
        libraries[name].depbuilders = [libraries[dep] for dep in entry["paths"] if dep in libraries]
        libraries[name].scanned = True
    # lib_deps packages precede the framework libraries in PlatformIO's discovery order.
    return sorted(libraries.values(), key=lambda lib: (lib.kind != "lib_deps", lib.name))


class Project(Library):
    def __init__(self, root: pathlib.Path):
        super().__init__(root, "project", root / "src",
                         [d for d in (root / "include", root / "src") if d.is_dir()], PROJECT_SRC_FILTER)

    def contains(self, file: pathlib.Path) -> bool:
        return any(d == file or d in file.parents for d in (self.path / "include", self.path / "src", self.path / "test"))


class Finder:
    """The dependency finder and the include paths it hands each library."""

    def __init__(self, root: pathlib.Path, compile_dirs: list[pathlib.Path] | None = None,
                 externals: dict | None = None):
        self.root = root.resolve()
        self.project = Project(self.root)
        if externals is None and EXTERNALS_FILE.is_file():
            externals = json.loads(EXTERNALS_FILE.read_text())
        self.externals = load_externals(externals) if externals else []
        lib_dir = self.root / "lib"
        self.libraries = [lib for lib in (Library.from_dir(d) for d in sorted(lib_dir.iterdir())
                                          if d.is_dir() and d.name != "__cores__") if lib] if lib_dir.is_dir() else []
        # Discovery searches the project directories and every library's directories.
        self.discovery_dirs = self.project.include_dirs() + [d for lib in self.libraries for d in lib.include_dirs()]
        # Library compile lines carry the -I directories of the shared build flags, nothing else of the project.
        self.compile_dirs = list(compile_dirs) if compile_dirs is not None else build_flag_include_dirs(self.root)
        # Every repository file, to tell a header that exists but is unreachable from an external one.
        self._repository_files = [file for directory in self.project.include_dirs() + [lib_dir]
                                  if directory.is_dir() for file in directory.rglob("*") if file.is_file()]
        self._paths: dict[Library, set[pathlib.Path]] = {}
        self._scan(self.project)

    def owner(self, file: pathlib.Path) -> Library | None:
        for lib in self.libraries + self.externals:
            if lib.contains(file):
                return lib
        return None

    def external_for(self, name: str) -> ExternalLibrary | None:
        """The external library that provides a header name, in PlatformIO's search order."""
        return next((lib for lib in self.externals if name in lib.headers), None)

    def found_includes(self, file: pathlib.Path, lib: Library) -> list[pathlib.Path]:
        """SCons' classic scanner: quoted includes search the file's directory first, angled ones last;
        the result is sorted by the include token including its quote characters."""
        found = []
        for opening, name, closing in INCLUDE.findall(file.read_text(errors="replace")):
            path = lib.include_dirs() + self.discovery_dirs
            dirs = [file.parent] + path if opening == '"' else path + [file.parent]
            for directory in dirs:
                candidate = directory / name
                if candidate.is_file():
                    found.append((f"{opening} {name} {closing}", candidate.resolve()))
                    break
            else:
                external = self.external_for(name)
                if external is not None:
                    found.append((f"{opening} {name} {closing}", external.path / name))
        return [candidate for _, candidate in sorted(found)]

    def implicit_includes(self, lib: Library, files: list[pathlib.Path]) -> list[pathlib.Path]:
        result: list[pathlib.Path] = []
        queue = list(files)
        while queue:
            file = queue.pop(0)
            if file in lib.processed:
                continue
            lib.processed.add(file)
            for candidate in self.found_includes(file, lib):
                if candidate not in lib.processed and candidate not in queue and lib.contains(candidate):
                    queue.append(candidate)
                if candidate not in result:
                    result.append(candidate)
        return result

    @staticmethod
    def already_depends(lib: Library, other: Library) -> bool:
        if lib in other.depbuilders:
            return True
        return any(Finder.already_depends(lib, dep) for dep in other.depbuilders)

    def _depend_on(self, lib: Library, other: Library) -> None:
        if lib is not other:
            if self.already_depends(lib, other):
                lib.circular.append(other)
            elif other not in lib.depbuilders:
                lib.depbuilders.append(other)
        self._scan(other)

    def _scan(self, lib: Library) -> None:
        if lib.scanned:
            return
        lib.scanned = True
        by_library: dict[Library, list[pathlib.Path]] = {}
        for include in self.implicit_includes(lib, lib.search_files()):
            owner = self.owner(include)
            if owner is not None and owner is not lib:
                by_library.setdefault(owner, []).append(include)
        for other in by_library:
            self._depend_on(lib, other)

    def include_paths(self, lib: Library) -> set[pathlib.Path]:
        """LibBuilderBase.build: own dirs, each dependency's full set, each circular dependency's own dirs."""
        if lib not in self._paths:
            paths = set(lib.include_dirs())
            for dep in lib.depbuilders:
                paths |= self.include_paths(dep)
            for dep in lib.circular:
                paths |= set(dep.include_dirs())
            self._paths[lib] = paths
        return self._paths[lib]

    def unresolved(self, lib: Library) -> list[tuple[str, str, str]]:
        """(file, include, owning library) for includes lib's compile cannot find."""
        if lib is self.project:
            paths = sorted(self.include_paths(lib) | set(self.project.include_dirs()) | set(self.compile_dirs), key=str)
        else:
            paths = sorted(self.include_paths(lib) | set(self.compile_dirs), key=str)
        seen: set[pathlib.Path] = set()
        problems: set[tuple[str, str, str]] = set()
        queue = list(lib.search_files())
        while queue:
            file = queue.pop()
            if file in seen:
                continue
            seen.add(file)
            for opening, name, _ in INCLUDE.findall(file.read_text(errors="replace")):
                # The compiler looks beside the including file for "..." only; <...> uses the include path.
                dirs = [file.parent] + paths if opening == '"' else paths
                hit = next((d / name for d in dirs if (d / name).is_file()), None)
                if hit is not None:
                    queue.append(hit.resolve())
                    continue
                external = self.external_for(name)
                if external is not None:
                    if external.path not in paths:
                        problems.add((str(file.relative_to(self.root)), name, external.describe()))
                    continue
                elsewhere = next((d / name for d in self.discovery_dirs if (d / name).is_file()), None)
                if elsewhere is None:
                    # Not on any include path: a repository file by that relative name is still a defect.
                    suffix = "/" + name.lstrip("./")
                    elsewhere = next((f for f in self._repository_files if f.as_posix().endswith(suffix)), None)
                if elsewhere is not None:
                    owner = self.owner(elsewhere.resolve())
                    problems.add((str(file.relative_to(self.root)), name, f"lib/{owner.name}" if owner else "the project"))
                    queue.append(elsewhere.resolve())
        return sorted(problems)

    def report(self) -> list[str]:
        """Problems of the project and of every library the finder reached; others are never built."""
        lines = []
        for lib in [self.project] + [lib for lib in self.libraries if lib.scanned]:
            for file, name, owner in self.unresolved(lib):
                lines.append(f"{lib.name}: {file} includes \"{name}\" from {owner}, which its compile does not receive")
        return lines


def build_flag_include_dirs(root: pathlib.Path) -> list[pathlib.Path]:
    """-I directories of platformio.ini build_flags, which reach every library's compile line.

    Every section's flags are read; this repository's only such flag is the shared ``-I include``."""
    ini = root / "platformio.ini"
    if not ini.is_file():
        print(f"note: no platformio.ini under {root}; no -I build flags applied", file=sys.stderr)
        return []
    config = configparser.ConfigParser(interpolation=None, strict=False, inline_comment_prefixes=(";", "#"))
    config.read(ini)
    dirs = []
    for section in config.sections():
        for token in re.findall(r"-I\s*(\S+)", config.get(section, "build_flags", fallback="")):
            directory = pathlib.Path(token.replace("${PROJECT_DIR}", str(root)))
            directory = directory if directory.is_absolute() else root / directory
            if directory.is_dir() and directory not in dirs:
                dirs.append(directory)
    return dirs


def runtime_identity(root: pathlib.Path) -> dict:
    """What the external data is tied to: the runtime lock and the platform pin."""
    identity = {}
    lock = root / RUNTIME_LOCK
    if lock.is_file():
        identity["runtimeLockSha256"] = hashlib.sha256(lock.read_bytes()).hexdigest()
    ini = root / "platformio.ini"
    if ini.is_file():
        match = re.search(r"^platform\s*=\s*(\S+)", ini.read_text(), re.M)
        if match:
            identity["platform"] = match.group(1)
    return identity


def generate_externals(root: pathlib.Path, store: pathlib.Path) -> dict:
    """Describe the framework libraries and lib_deps packages of a finished build's private store."""
    dirs: list[tuple[str, pathlib.Path]] = []
    for libdeps in sorted((store / "libdeps").glob("*/")):
        dirs += [("lib_deps", d) for d in sorted(libdeps.iterdir()) if d.is_dir()]
    framework = store / "packages" / "framework-arduinoespressif32" / "libraries"
    dirs += [("framework", d) for d in sorted(framework.iterdir()) if d.is_dir()]
    libraries: dict[str, tuple[str, Library]] = {}
    for kind, directory in dirs:
        lib = Library.from_dir(directory)
        if lib is not None and (lib.search_files() or any(lib.include_dirs())):
            libraries[lib.name] = (kind, lib)
    # Dependencies among the externals, with the same discovery and cycle rules.
    finder = Finder.__new__(Finder)
    finder.root, finder.externals, finder.libraries = store, [], [lib for _, lib in libraries.values()]
    finder.project = Project(store)
    finder.project.scanned = True
    finder.discovery_dirs = [d for lib in finder.libraries for d in lib.include_dirs()]
    finder.compile_dirs, finder._repository_files, finder._paths = [], [], {}
    for lib in finder.libraries:
        finder._scan(lib)
    data = {"libraries": {}}
    data.update(runtime_identity(root))
    for name, (kind, lib) in sorted(libraries.items()):
        headers = sorted({str(f.relative_to(d)) for d in lib.include_dirs() if d.is_dir()
                          for f in d.rglob("*") if f.is_file() and f.suffix.lstrip(".") in HEADER_EXT})
        others = {other.name for other in finder.libraries
                  if other is not lib and set(other.include_dirs()) & finder.include_paths(lib)}
        data["libraries"][name] = {"kind": kind, "headers": headers, "paths": sorted(others)}
    return data


def _tree(root: pathlib.Path, files: dict[str, str]) -> pathlib.Path:
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return root


class FinderRuleTests(unittest.TestCase):
    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self._temporary.name).resolve()

    def tearDown(self):
        self._temporary.cleanup()

    def finder(self, files: dict[str, str], compile_dirs=(), externals: dict | None = None) -> Finder:
        _tree(self.root, files)
        return Finder(self.root, [self.root / d for d in compile_dirs], externals or {"libraries": {}})

    def library(self, finder: Finder, name: str) -> Library:
        return next(lib for lib in finder.libraries if lib.name == name)

    def names(self, libs) -> list[str]:
        return [lib.name for lib in libs]

    def test_direct_dependency_brings_its_own_paths(self):
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n',
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include "b.hpp"\n',
            "lib/b/b.hpp": '#include "c.hpp"\n', "lib/b/b.cpp": '#include "b.hpp"\n',
            "lib/c/c.hpp": "",
        })
        self.assertEqual(self.names(self.library(finder, "a").depbuilders), ["b"])
        self.assertEqual(self.names(self.library(finder, "b").depbuilders), ["c"])
        self.assertEqual(finder.report(), [])

    def test_cycle_contributes_only_its_own_directory(self):
        finder = self.finder({
            "src/main.cpp": '#include "b.hpp"\n',
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include "b.hpp"\n',
            "lib/b/b.hpp": '#include "c.hpp"\n', "lib/b/b.cpp": '#include "b.hpp"\n#include "../a/a.hpp"\n',
            "lib/c/c.hpp": "",
        })
        self.assertEqual(self.names(self.library(finder, "b").depbuilders), ["a", "c"])
        self.assertEqual(self.names(self.library(finder, "a").circular), ["b"])
        self.assertEqual(finder.report(), ['a: lib/b/b.hpp includes "c.hpp" from lib/c, which its compile does not receive'])

    def test_relative_include_survives_a_cycle(self):
        finder = self.finder({
            "src/main.cpp": '#include "b.hpp"\n',
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include "b.hpp"\n',
            "lib/b/b.hpp": '#include "../c/c.hpp"\n', "lib/b/b.cpp": '#include "../a/a.hpp"\n',
            "lib/c/c.hpp": "",
        })
        self.assertEqual(finder.report(), [])

    def test_only_the_library_s_own_sources_are_scanned(self):
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n',
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include "b.hpp"\n',
            "lib/b/b.hpp": '#include "c.hpp"\n', "lib/b/b.cpp": "", "lib/c/c.hpp": "",
        })
        self.assertEqual(self.names(self.library(finder, "a").depbuilders), ["b"])

    def test_header_only_library_does_not_carry_its_includes(self):
        # The finder scans source files only, so nothing discovers what a
        # header-only library's headers include; whoever compiles them must.
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n',
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include "b.hpp"\n',
            "lib/b/b.hpp": '#include "c.hpp"\n', "lib/c/c.hpp": "",
        })
        self.assertEqual(self.names(self.library(finder, "b").depbuilders), [])
        self.assertEqual(finder.report(), ['a: lib/b/b.hpp includes "c.hpp" from lib/c, which its compile does not receive'])

    def test_includes_follow_scons_token_order(self):
        # Quoted before angled, upper case before lower case: '" Z.hpp "' < '" b.hpp "' < '< c.hpp >'.
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n',
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include <c.hpp>\n#include "b.hpp"\n#include "Z.hpp"\n',
            "lib/b/b.hpp": "", "lib/c/c.hpp": "", "lib/Z/Z.hpp": "",
        })
        self.assertEqual(self.names(self.library(finder, "a").depbuilders), ["Z", "b", "c"])

    def test_order_decides_which_edge_of_a_cycle_breaks(self):
        # main.cpp reaches a before b, so a -> b is a real dependency and b -> a closes the cycle:
        # b compiles with only a's own directory and cannot see c through a.
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n#include "b.hpp"\n',
            "lib/a/a.hpp": '#include "c.hpp"\n', "lib/a/a.cpp": '#include "a.hpp"\n#include "b.hpp"\n',
            "lib/b/b.hpp": "", "lib/b/b.cpp": '#include "a.hpp"\n',
            "lib/c/c.hpp": "",
        })
        self.assertEqual(self.names(self.library(finder, "a").depbuilders), ["b", "c"])
        self.assertEqual(self.names(self.library(finder, "b").circular), ["a"])
        self.assertEqual(finder.report(), ['b: lib/a/a.hpp includes "c.hpp" from lib/c, which its compile does not receive'])

    def test_angled_include_resolves_through_the_include_path_only(self):
        # Discovery (SCons) tries the file's directory last for <...>, so b is found and
        # scanned, but the compiler never looks beside the file for an angled include.
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n',
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include <nested/x.hpp>\n', "lib/a/nested/x.hpp": '#include <y.hpp>\n',
            "lib/a/nested/y.hpp": '#include "../../b/b.hpp"\n', "lib/b/b.hpp": "", "lib/b/b.cpp": "",
        })
        self.assertEqual(self.names(self.library(finder, "a").depbuilders), ["b"])
        self.assertEqual(finder.report(), ['a: lib/a/nested/x.hpp includes "y.hpp" from lib/a, which its compile does not receive'])

    def test_build_flag_include_directory_is_on_every_compile_line_but_src_is_not(self):
        files = {
            "src/main.cpp": '#include "a.hpp"\n', "include/hal.hpp": "", "src/private.hpp": "",
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include "hal.hpp"\n#include "private.hpp"\n',
        }
        finder = self.finder(files, compile_dirs=["include"])
        self.assertEqual(finder.report(), ['a: lib/a/a.cpp includes "private.hpp" from the project, which its compile does not receive'])
        _tree(self.root, {"platformio.ini": "[env:x]\nbuild_flags =\n  -I include  ; global headers\n"})
        self.assertEqual(build_flag_include_dirs(self.root), [self.root / "include"])

    def test_manifest_source_filter_matches_like_platformio(self):
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n',
            "lib/a/library.json": '{"build": {"srcFilter": ["+<*>", "-<*.c>", "-<platform/>"]}}',
            "lib/a/a.hpp": "", "lib/a/top.c": '#include "b.hpp"\n', "lib/a/deep/keep.c": '#include "c.hpp"\n',
            "lib/a/platform/skipped.cpp": '#include "d.hpp"\n',
            "lib/b/b.hpp": "", "lib/c/c.hpp": "", "lib/d/d.hpp": "",
        })
        # -<*.c> removes only top-level .c files; -<platform/> removes the directory; deep/keep.c stays.
        self.assertEqual(self.names(self.library(finder, "a").depbuilders), ["c"])

    def test_default_filter_skips_examples_and_tests_only_at_the_top(self):
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n',
            "lib/a/a.hpp": "", "lib/a/a.cpp": "", "lib/a/examples/demo.cpp": '#include "b.hpp"\n',
            "lib/a/nested/tests/t.cpp": '#include "c.hpp"\n',
            "lib/b/b.hpp": "", "lib/c/c.hpp": "",
        })
        self.assertEqual(self.names(self.library(finder, "a").depbuilders), ["c"])

    def test_arduino_style_library_without_src_scans_only_top_level_and_utility(self):
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n',
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include "Arduino.h"\n#include "b.hpp"\n',
            "lib/a/utility/u.cpp": '#include "c.hpp"\n', "lib/a/deep/x.cpp": '#include "d.hpp"\n',
            "lib/b/b.hpp": "", "lib/c/c.hpp": "", "lib/d/d.hpp": "",
        })
        self.assertEqual(self.names(self.library(finder, "a").depbuilders), ["b", "c"])
        self.assertEqual(self.library(finder, "a").include_dirs(), [self.root / "lib/a", self.root / "lib/a/utility"])

    def test_project_follows_only_its_own_directories(self):
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n',
            "lib/a/a.hpp": '#include "b.hpp"\n', "lib/a/a.cpp": "", "lib/b/b.hpp": "",
        })
        # b is reached only through a's header, which the project does not scan on a's behalf.
        self.assertEqual(self.names(finder.project.depbuilders), ["a"])


    def test_second_entry_into_a_library_scans_nothing_new(self):
        # Deep mode replaces the passed files with the library's own sources on every
        # entry, so a header-only library reached from two includers still carries nothing.
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n#include "b.hpp"\n',
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include "b.hpp"\n',
            "lib/b/b.hpp": '#include "c.hpp"\n', "lib/c/c.hpp": "",
        })
        self.assertEqual(self.names(self.library(finder, "b").depbuilders), [])
        self.assertEqual(finder.report(), [
            'project: lib/b/b.hpp includes "c.hpp" from lib/c, which its compile does not receive',
            'a: lib/b/b.hpp includes "c.hpp" from lib/c, which its compile does not receive'])

    def test_unreached_libraries_are_not_graded(self):
        finder = self.finder({
            "src/main.cpp": "",
            "lib/orphan/orphan.cpp": '#include "missing_everywhere.hpp"\n#include "b.hpp"\n', "lib/b/b.hpp": "",
        })
        self.assertFalse(self.library(finder, "orphan").scanned)
        self.assertEqual(finder.report(), [])

    def test_external_libraries_propagate_like_repository_ones(self):
        externals = {"libraries": {
            "WiFi": {"kind": "framework", "headers": ["WiFi.h"], "paths": ["Network"]},
            "Network": {"kind": "framework", "headers": ["NetworkClient.h"], "paths": []},
        }}
        finder = self.finder({
            "src/main.cpp": '#include "a.hpp"\n#include "d.hpp"\n',
            # a includes WiFi itself and so receives Network through it.
            "lib/a/a.hpp": "", "lib/a/a.cpp": '#include <WiFi.h>\n#include <NetworkClient.h>\n',
            # d reaches WiFi.h only through the header-only b, as lib/lvgl did through power.hpp.
            "lib/b/b.hpp": '#include <WiFi.h>\n',
            "lib/d/d.hpp": "", "lib/d/d.cpp": '#include "b.hpp"\n',
        }, externals=externals)
        self.assertEqual(self.names(self.library(finder, "a").depbuilders), ["Network", "WiFi"])
        self.assertEqual(finder.report(), ['d: lib/b/b.hpp includes "WiFi.h" from the WiFi framework library, which its compile does not receive'])


class RepositoryTests(unittest.TestCase):
    root = pathlib.Path(__file__).resolve().parents[2]

    def test_external_library_data_matches_the_locked_runtime(self):
        data = json.loads(EXTERNALS_FILE.read_text())
        self.assertEqual({k: data.get(k) for k in ("runtimeLockSha256", "platform")}, runtime_identity(self.root),
                         "the runtime changed: regenerate with --update-externals <.pio/open-bike-build/platformio/ENV>")
        self.assertIn("WiFi", data["libraries"])

    def test_every_library_resolves_its_includes(self):
        finder = Finder(self.root)
        self.assertEqual(finder.report(), [])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=pathlib.Path, help="esp32 directory to check (default: this repository's)")
    parser.add_argument("--list", action="store_true", help="print each library's dependencies and stop")
    parser.add_argument("--update-externals", type=pathlib.Path, metavar="STORE_DIR",
                        help="regenerate ldf_external_libraries.json from a finished build's private store")
    args, rest = parser.parse_known_args(argv)
    if args.root is not None:
        RepositoryTests.root = args.root.resolve()
    if args.update_externals is not None:
        data = generate_externals(RepositoryTests.root, args.update_externals.resolve())
        EXTERNALS_FILE.write_text(json.dumps(data, indent=1, sort_keys=True) + "\n")
        print(f"wrote {EXTERNALS_FILE.name}: {len(data['libraries'])} external libraries")
        return 0
    if args.list:
        finder = Finder(RepositoryTests.root)
        for lib in [finder.project] + finder.libraries:
            print(f"{lib.name}: deps={[d.name for d in lib.depbuilders]} circular={[d.name for d in lib.circular]}")
        problems = finder.report()
        for line in problems:
            print("unresolved:", line)
        return 1 if problems else 0
    program = unittest.main(argv=[sys.argv[0]] + rest, exit=False)
    return 0 if program.result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
