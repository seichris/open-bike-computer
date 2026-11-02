import tempfile
import subprocess
import sys
import unittest
import os
import shutil
from pathlib import Path
from unittest.mock import Mock

from build_firmware import _application_build_cache_identity
from firmware_compile_cache import (
    configure_metadata_identity,
    declared_no_exception_libraries,
    elf_section_names,
    relocate_core_text,
    verify_no_exception_objects,
)
if __package__:
    from .elf_fixtures import write_elf_object
else:
    from elf_fixtures import write_elf_object


class FirmwareCompileCacheTests(unittest.TestCase):
    def test_relocated_platformio_file_location_stays_a_raw_filesystem_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            origin = root / "producer"
            target = root / "consumer with a longer path"
            target.mkdir()
            metadata = target / ".piopm"
            metadata.write_text('{"uri":"file://' + str(origin / "platform-staging") + '"}')
            self.assertEqual(relocate_core_text(target, origin, target), 1)
            self.assertIn("file://" + str(target / "platform-staging"), metadata.read_text())
            self.assertNotIn("%20", metadata.read_text())

    @unittest.skipUnless(shutil.which("cc"), "host C compiler is unavailable")
    def test_compiler_clock_is_independent_of_commit_epoch_and_source_mtime(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            env = Mock()
            env.subst.side_effect = {"$PROJECT_DIR": str(project), "$PIOENV": "WAVESHARE_AMOLED_175"}.__getitem__
            configure_metadata_identity(env, "a" * 40, "2026-10-01T00:00:00Z")
            clock = project / ".pio/open-bike-build/build-identity/WAVESHARE_AMOLED_175/firmware_compile_clock.h"
            source = project / "clock.c"
            source.write_text('const char *clock = __DATE__ " " __TIME__ " " __TIMESTAMP__;\n')
            outputs = []
            for epoch in (0, 1790859494):
                os.utime(source, (epoch, epoch))
                result = subprocess.run(
                    [shutil.which("cc"), "-E", "-P", "-Werror=date-time", "-include", str(clock), str(source)],
                    env={**os.environ, "SOURCE_DATE_EPOCH": str(epoch)},
                    check=True, capture_output=True, text=True,
                )
                outputs.append(result.stdout)
            self.assertEqual(outputs[0], outputs[1])
            self.assertIn('"Jan  1 1970" " " "00:00:00"', outputs[0])

    def test_rebases_percent_encoded_package_urls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            origin = root / "old producer"
            target = root / "new consumer"
            target.mkdir()
            metadata = target / ".piopm"
            metadata.write_text('{"uri":"' + (origin / "platform-staging").as_uri() + '"}')
            self.assertEqual(relocate_core_text(target, origin, target), 1)
            self.assertIn((target / "platform-staging").as_uri(), metadata.read_text())

    def test_relocated_python_launcher_executes_in_path_with_spaces_and_quotes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            origin = root / "producer"
            target = root / "consumer with 'quotes'"
            (target / "bin").mkdir(parents=True)
            (target / "bin/python").symlink_to(sys.executable)
            launcher = target / "bin/launch"
            launcher.write_text(f"#!{origin}/bin/python\nprint('relocated')\n")
            launcher.chmod(0o755)
            self.assertEqual(relocate_core_text(target, origin, target), 1)
            result = subprocess.run([str(launcher)], check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout, "relocated\n")

    def test_source_commit_keeps_library_namespace_but_core_change_does_not(self):
        project = Path("/project")
        first = _application_build_cache_identity(project, "WAVESHARE_AMOLED_175", "a" * 40, "1" * 64)
        self.assertEqual(first, _application_build_cache_identity(project, "WAVESHARE_AMOLED_175", "b" * 40, "1" * 64))
        self.assertNotEqual(first, _application_build_cache_identity(project, "WAVESHARE_AMOLED_175", "a" * 40, "2" * 64))

    def test_gfx_library_objects_compile_without_exceptions(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            env = Mock()
            substitutions = {"$PROJECT_DIR": str(project), "$PIOENV": "WAVESHARE_AMOLED_175"}
            env.subst.side_effect = lambda value: substitutions.get(value, value)
            flags = {
                "CXXFLAGS": ["-std=gnu++2b", "-fexceptions", "-fno-rtti"],
                "CCFLAGS": ["-Os", ("-include", "include/nimble_connection_config.h"), "-fexceptions"],
            }
            env.get.side_effect = lambda name, default=None: flags.get(name, default)
            configure_metadata_identity(env, "a" * 40, "2026-10-01T00:00:00Z")
            callback = env.AddBuildMiddleware.call_args.args[0]
            env.Object.return_value = [Mock()]
            libdeps = project / ".pio/open-bike-build/platformio/WAVESHARE_AMOLED_175/libdeps/WAVESHARE_AMOLED_175"
            gfx = Mock()
            gfx.srcnode.return_value.get_abspath.return_value = str(libdeps / "GFX Library for Arduino/src/Arduino_GFX.cpp")
            self.assertIs(callback(env, gfx), env.Object.return_value[0])
            # Both flag lists lose -fexceptions; the override goes last, after $CCFLAGS.
            self.assertEqual(env.Object.call_args.kwargs, {
                "CXXFLAGS": ["-std=gnu++2b", "-fno-rtti"],
                "CCFLAGS": ["-Os", ("-include", "include/nimble_connection_config.h"), "-fno-exceptions"],
            })
            # Every other object, including other libraries and C sources, keeps the framework flags.
            for relative in ("lib/gui/src/mainScr.cpp", "NimBLE-Arduino/src/NimBLEDevice.cpp", "GFX Library for Arduino/src/font.c"):
                node = Mock()
                node.srcnode.return_value.get_abspath.return_value = str((libdeps if "/src/" in relative and not relative.startswith("lib/") else project) / relative)
                callback(env, node)
                self.assertEqual(env.Object.call_args.kwargs, {}, relative)

    def test_no_exception_objects_are_verified_from_their_section_tables(self):
        with tempfile.TemporaryDirectory() as directory:
            build_dir = Path(directory).resolve()
            gfx = build_dir / "lib306/GFX Library for Arduino"
            with self.assertRaisesRegex(RuntimeError, "no objects"):
                verify_no_exception_objects(build_dir)
            write_elf_object(gfx / "Arduino_GFX.cpp.o", (".text", ".literal", ".rela.text", ".symtab", ".strtab"))
            write_elf_object(gfx / "display/Arduino_CO5300.cpp.o", (".text.draw", ".rodata", ".debug_info"))
            self.assertEqual(verify_no_exception_objects(build_dir), 2)
            self.assertEqual(elf_section_names(gfx / "Arduino_GFX.cpp.o"),
                             ["", ".text", ".literal", ".rela.text", ".symtab", ".strtab", ".shstrtab"])
            # An unrelated library keeps its tables without failing the check.
            write_elf_object(build_dir / "lib123/NimBLE-Arduino/NimBLEDevice.cpp.o", (".text", ".eh_frame"))
            self.assertEqual(verify_no_exception_objects(build_dir), 2)
            write_elf_object(gfx / "databus/Arduino_ESP32QSPI.cpp.o", (".text", ".eh_frame", ".rela.eh_frame"))
            with self.assertRaisesRegex(RuntimeError, r"exception tables: lib306/GFX Library for Arduino/databus/Arduino_ESP32QSPI\.cpp\.o"):
                verify_no_exception_objects(build_dir)
            write_elf_object(gfx / "databus/Arduino_ESP32QSPI.cpp.o", (".text", ".gcc_except_table.fn", ".literal"))
            with self.assertRaisesRegex(RuntimeError, "exception tables"):
                verify_no_exception_objects(build_dir)
            (gfx / "databus/Arduino_ESP32QSPI.cpp.o").write_bytes(b"not an object")
            with self.assertRaisesRegex(ValueError, "not a 32-bit little-endian ELF"):
                verify_no_exception_objects(build_dir)

    def test_declared_no_exception_libraries_follow_extends_and_references(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            (project / "platformio.ini").write_text(
                "[common]\n"
                "lib_deps =\n"
                "  bblanchon/ArduinoJson @ 7.0.0\n"
                "  moononournation/GFX Library for Arduino @ 1.6.7\n"
                "\n"
                "[waveshare_base]\n"
                "lib_deps =\n"
                "  ${common.lib_deps}\n"
                "  ; a comment inside the list\n"
                "  h2zero/NimBLE-Arduino @ 1.4.3\n"
                "\n"
                "[env:WAVESHARE_AMOLED_175_PRODUCTION]\n"
                "extends = waveshare_base\n"
                "\n"
                "[env:WAVESHARE_AMOLED_175_PERSONAL]\n"
                "extends = env:WAVESHARE_AMOLED_175_PRODUCTION\n"
                "\n"
                "[env:LEGACY]\n"
                "lib_deps =\n"
                "  ; moononournation/GFX Library for Arduino @ 1.4.7\n"
                "  bblanchon/ArduinoJson @ 7.0.0\n"
                "\n"
                "[env:BARE]\n"
                "platform = test\n",
                encoding="utf-8",
            )
            self.assertEqual(declared_no_exception_libraries(project, "WAVESHARE_AMOLED_175_PRODUCTION"), {"GFX Library for Arduino"})
            self.assertEqual(declared_no_exception_libraries(project, "WAVESHARE_AMOLED_175_PERSONAL"), {"GFX Library for Arduino"})
            self.assertEqual(declared_no_exception_libraries(project, "LEGACY"), frozenset())
            self.assertEqual(declared_no_exception_libraries(project, "BARE"), frozenset())
            self.assertEqual(declared_no_exception_libraries(project, "MISSING"), frozenset())

    def test_identity_header_changes_only_metadata_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            env = Mock()
            env.subst.side_effect = {"$PROJECT_DIR": str(project), "$PIOENV": "WAVESHARE_AMOLED_175"}.__getitem__
            configure_metadata_identity(env, "a" * 40, "2026-10-01T00:00:00Z")
            callback = env.AddBuildMiddleware.call_args.args[0]
            metadata = Mock()
            metadata.srcnode.return_value.get_abspath.return_value = str(project / "lib/firmware_metadata/firmware_metadata.cpp")
            unrelated = Mock()
            unrelated.srcnode.return_value.get_abspath.return_value = str(project / "lib/lvgl/lvgl.cpp")
            env.Object.return_value = [Mock()]
            self.assertIs(callback(env, unrelated), env.Object.return_value[0])
            env.Depends.assert_called_once_with(env.Object.return_value, [
                str(project / ".pio/open-bike-build/build-identity/WAVESHARE_AMOLED_175/firmware_compile_clock.h"),
                str(project / "lib/lvgl/lv_conf.h"),
            ])
            env.Clone.assert_not_called()
            env.Clone.return_value.Object.return_value = [Mock()]
            self.assertIs(callback(env, metadata), env.Clone.return_value.Object.return_value[0])
            clone = env.Clone.return_value
            self.assertEqual(clone.Depends.call_count, 2)
            header = Path(clone.Depends.call_args.args[1])
            before = header.read_text()
            configure_metadata_identity(env, "b" * 40, "2026-10-02T00:00:00Z")
            after = header.read_text()
            self.assertIn("a" * 40, before)
            self.assertNotIn("a" * 40, after)
            self.assertIn("b" * 40, after)
            self.assertIn("2026-10-02T00:00:00Z", after)

    @unittest.skipUnless(shutil.which("cc"), "host C compiler is unavailable")
    def test_macro_included_configuration_invalidates_warm_scons_objects(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            config = project / "lib/lvgl/lv_conf.h"
            config.parent.mkdir(parents=True)
            config.write_text("#define LV_MEM_SIZE (96 * 1024U)\n")
            (project / "probe.c").write_text('''#include <stdio.h>
#define STR_(x) #x
#define STR(x) STR_(x)
#include STR(LV_CONF_PATH)
int main(void) { printf("%u\\n", LV_MEM_SIZE); }
''')
            tools = Path(__file__).resolve().parents[1]
            (project / "SConstruct").write_text(f'''
import sys
sys.path.insert(0, {str(tools)!r})
from firmware_compile_cache import configure_metadata_identity
env = Environment()
env["PROJECT_DIR"] = Dir(".").abspath
env["PIOENV"] = "WAVESHARE_AMOLED_175"
env.Append(CPPDEFINES=[("LV_CONF_PATH", {str(config)!r})])
callbacks = []
env.AddMethod(lambda self, callback: callbacks.append(callback), "AddBuildMiddleware")
configure_metadata_identity(env, ARGUMENTS.get("commit", "a" * 40), "2026-10-01T00:00:00Z")
env.CacheDir("objects-cache")
obj = callbacks[0](env, File("probe.c"))
env.Program("probe", [obj])
''')
            command = [sys.executable, "-c", "from SCons.Script import main; main()", "-Q"]

            def build(expected, *, commit="a" * 40):
                result = subprocess.run(command + ["commit=" + commit], cwd=project,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                output = subprocess.check_output([str(project / "probe")], text=True)
                self.assertEqual(int(output), expected)
                return result.stdout

            build(96 * 1024)
            config.write_text("#define LV_MEM_SIZE (192 * 1024U)\n")
            build(192 * 1024)
            # Reuse both versions from the object cache without clearing it.
            for kib in (96, 192):
                config.write_text(f"#define LV_MEM_SIZE ({kib} * 1024U)\n")
                (project / "probe.o").unlink()
                (project / "probe").unlink()
                self.assertIn("from cache", build(kib * 1024))
            before = (project / "probe.o").stat().st_mtime_ns
            build(192 * 1024, commit="b" * 40)
            self.assertEqual(before, (project / "probe.o").stat().st_mtime_ns)

    def test_force_included_files_cover_platformio_and_direct_flag_forms(self):
        from firmware_compile_cache import force_included_files
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            names = ["include/a.h", "b.h", "c.h", "d.h", "e.h"]
            for name in names:
                (project / name).parent.mkdir(parents=True, exist_ok=True)
                (project / name).write_text("")

            class Env(dict):
                def subst(self, value):
                    return value

            env = Env(
                # PlatformIO pair, direct pair of strings, joined, -imacros, and
                # a missing file (never declared: SCons would fail the build).
                CCFLAGS=[("-include", "include/a.h"), "-Wall", "-include", str(project / "b.h"),
                         f"-include{project / 'c.h'}", ("-imacros", "d.h"), ("-include", "missing.h")],
                CFLAGS="-include e.h",
                CXXFLAGS=None,
            )
            self.assertEqual(force_included_files(env, project), [str(project / name) for name in names])

    @unittest.skipUnless(shutil.which("cc"), "host C compiler is unavailable")
    def test_force_included_header_invalidates_warm_scons_objects(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            forced = project / "include/forced_config.h"
            forced.parent.mkdir(parents=True)
            (project / "lib/lvgl").mkdir(parents=True)
            (project / "lib/lvgl/lv_conf.h").write_text("")
            (project / "probe.c").write_text(
                '#include <stdio.h>\nint main(void) { printf("%d\\n", FORCED_LIMIT); }\n')
            tools = Path(__file__).resolve().parents[1]
            (project / "SConstruct").write_text(f'''
import sys
sys.path.insert(0, {str(tools)!r})
from firmware_compile_cache import configure_metadata_identity
env = Environment()
env["PROJECT_DIR"] = Dir(".").abspath
env["PIOENV"] = "WAVESHARE_AMOLED_175"
# Like a PlatformIO build flag; SCons' scanner never reads compiler flags.
env.MergeFlags("-include include/forced_config.h")
callbacks = []
env.AddMethod(lambda self, callback: callbacks.append(callback), "AddBuildMiddleware")
configure_metadata_identity(env, "a" * 40, "2026-10-01T00:00:00Z")
env.CacheDir("objects-cache")
obj = callbacks[0](env, File("probe.c"))
env.Program("probe", [obj])
''')
            command = [sys.executable, "-c", "from SCons.Script import main; main()", "-Q"]

            def build(limit):
                forced.write_text(f"#define FORCED_LIMIT {limit}\n")
                result = subprocess.run(command, cwd=project, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                output = subprocess.check_output([str(project / "probe")], text=True)
                self.assertEqual(int(output), limit)
                return result.stdout

            build(1)
            build(3)
            # Reuse both versions from the object cache without clearing it.
            for limit in (1, 3):
                (project / "probe.o").unlink()
                (project / "probe").unlink()
                self.assertIn("from cache", build(limit))

    def test_symlinked_identity_header_is_rejected_without_touching_target(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory).resolve()
            env = Mock()
            env.subst.side_effect = {"$PROJECT_DIR": str(project), "$PIOENV": "WAVESHARE_AMOLED_175"}.__getitem__
            header = project / ".pio/open-bike-build/build-identity/WAVESHARE_AMOLED_175/firmware_identity.h"
            header.parent.mkdir(parents=True)
            outside = project / "outside"
            outside.write_text("preserved")
            header.symlink_to(outside)
            with self.assertRaisesRegex(RuntimeError, "unsafe firmware identity"):
                configure_metadata_identity(env, "a" * 40, "time")
            self.assertEqual(outside.read_text(), "preserved")
