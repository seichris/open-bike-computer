"""Maps live only on removable SD, and the boot's storage backend stays pinned.

These tests compile the production Storage and map-renderer entry points into
host harnesses whose filesystem, card and FFat are fakes that count every call.
Each harness also runs against small mutations of the production text, so a
reintroduced FFat map read or live backend switch fails the test instead of
merely changing source shape.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "tools/tests"


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def between(text, start, end):
    first = text.index(start)
    return text[first:text.index(end, first)]


def run_harness(text, name, extra_args=(), flags=()):
    with tempfile.TemporaryDirectory() as directory:
        unit = Path(directory) / f"{name}.cpp"
        binary = Path(directory) / name
        unit.write_text(text, encoding="utf-8")
        subprocess.run(
            ["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror", *flags,
             "-I", str(TESTS), str(unit), "-o", str(binary)],
            check=True)
        return subprocess.run([str(binary), *extra_args], capture_output=True,
                              text=True)


def mutated(text, old, new):
    if old not in text:
        raise AssertionError("mutation anchor missing: " + old)
    return text.replace(old, new, 1)


def matching_brace(text, opening):
    depth = 0
    index = opening
    while index < len(text):
        if text.startswith("//", index):
            index = text.index("\n", index)
        elif text.startswith("/*", index):
            index = text.index("*/", index) + 1
        elif text[index] in "\"'":
            quote = text[index]
            index += 1
            while text[index] != quote:
                index += 2 if text[index] == "\\" else 1
        elif text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise AssertionError("unterminated definition")


def definition(text, signature):
    """Returns one production function, including a function-try handler."""
    start = text.index(signature)
    end = matching_brace(text, text.index("{", start))
    handler = len(text) - len(text[end + 1:].lstrip())
    if text.startswith("catch", handler):
        end = matching_brace(text, text.index("{", handler))
    return text[start:end + 1] + "\n"


RENDERER_ENTRY_POINTS = (
    "bool mapFilesAvailable()",
    "bool findMapBlock(",
    "Maps::MapBlock *Maps::readMapBlock(String fileName)",
    "map_probe_diagnostics::Result\nMaps::probeVectorMapFolderOnStorageOwner(",
    "bool Maps::switchVectorMapFolderOnStorageOwner(",
    "bool Maps::requestStorageControl(",
    "bool Maps::requestVectorMapFolderActivation(",
    "bool Maps::processPendingNearbySearch()",
    "void Maps::bindMapStorageRoot(",
)


def renderer_harness(mutate=None):
    maps = source("lib/maps/src/maps.cpp")
    renderer = "".join(definition(maps, signature)
                       for signature in RENDERER_ENTRY_POINTS)
    if mutate is not None:
        renderer = mutate(renderer)
    harness = source("tools/tests/map_storage_boundary_harness.cpp")
    return harness.replace("// PRODUCTION_RENDERER", renderer)


def run_renderer(text, name):
    with tempfile.TemporaryDirectory() as root:
        installed = Path(root) / "maps/a"
        (installed / "+000+000").mkdir(parents=True)
        (installed / "assets").mkdir()
        (installed / "+000+000/0_0.fmb").write_bytes(b"FMB-test-block")
        (installed / "+000+000/0_0.fme").write_bytes(b"terrain!")
        (installed / "assets/street-labels.fma").write_bytes(b"font")
        # readMapBlock's legacy ASCII parser keeps two unused locals.
        return run_harness(text, name, (root,),
                           ("-Wno-unused-variable",
                            "-Wno-unused-but-set-variable"))


def storage_harness(mutate=None):
    header = "\n".join(
        line for line in source("lib/storage/storage.hpp").splitlines()
        if not line.startswith(("#include", "#pragma")))
    header = header.replace("private:", "public:")
    cpp = source("lib/storage/storage.cpp")
    unavailable_root = next(
        line.strip() for line in cpp.splitlines() if "kUnavailableMapRoot =" in line)
    methods = "\n".join([
        between(cpp, "Storage::Storage()", "bool Storage::pollShutdownQuiescence()"),
        between(cpp, "void Storage::pinBackendForBoot()",
                "const char *Storage::storageBackendName() const"),
        between(cpp, "StoragePreparation Storage::prepareDiagnosticsStorage()",
                "uint64_t Storage::diagnosticsSdFreeBytes() const"),
        between(cpp, "esp_err_t Storage::initSD()",
                "esp_err_t Storage::mountRemovableStorage()"),
        between(cpp, "esp_err_t Storage::initSPIFFS()",
                "SDCardInfo Storage::getSDCardInfo()"),
        between(cpp, "bool Storage::getSdLoaded() const", "\n/**"),
    ])
    if mutate is not None:
        methods = mutate(methods)
    harness = source("tools/tests/storage_backend_pin_harness.cpp")
    harness = harness.replace("// PRODUCTION_HEADER", header)
    harness = harness.replace("// PRODUCTION_UNAVAILABLE_ROOT", unavailable_root)
    return harness.replace("// PRODUCTION_METHODS", methods)


class BootPinnedStorageTests(unittest.TestCase):
    def test_backend_is_pinned_and_maps_never_resolve_to_ffat(self):
        result = run_harness(storage_harness(), "storage_pin")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_live_backend_switch_or_ffat_map_root_is_detected(self):
        mutations = {
            "explicit initSD after pin mounts again": lambda methods: mutated(
                methods,
                "  if (!storage_mount_policy::mayChangeMount(backendPinned()))\n"
                "    return ESP_ERR_INVALID_STATE;\n"
                "  return mountRemovableStorage();",
                "  return mountRemovableStorage();"),
            "map-download validation remounts a card": lambda methods: mutated(
                methods, "  if (!ready)\n    isSdLoaded = false;",
                "  if (!ready && mountRemovableStorage() != ESP_OK)\n"
                "    isSdLoaded = false;"),
            "FFat fallback re-mounted at runtime": lambda methods: mutated(
                methods,
                "esp_err_t Storage::initSPIFFS() {\n"
                "  if (!storage_mount_policy::mayChangeMount(backendPinned()))\n"
                "    return ESP_ERR_INVALID_STATE;",
                "esp_err_t Storage::initSPIFFS() {"),
            "map root names FFat's mount": lambda methods: mutated(
                methods, 'return mapStorageAvailable() ? "/sdcard" : kUnavailableMapRoot;',
                'return "/sdcard";'),
            "FFat counted as map storage": lambda methods: mutated(
                methods,
                "removableHoldsMaps(isSdLoaded.load(),\n"
                "                                               internalFallbackMounted.load())",
                "removableHoldsMaps(true, false)"),
        }
        for name, mutate in mutations.items():
            with self.subTest(name):
                result = run_harness(storage_harness(mutate), "storage_pin_mutant")
                self.assertEqual(result.returncode, 42, result.stderr)


class SdOnlyRendererStorageTests(unittest.TestCase):
    def test_renderer_reads_maps_only_from_removable_storage(self):
        result = run_renderer(renderer_harness(), "map_storage")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reintroduced_map_io_without_removable_storage_is_detected(self):
        gate = "if (!mapFilesAvailable())"
        mutations = {
            "map storage treated as always present": (
                "bool mapFilesAvailable() { return storage.mapStorageAvailable(); }",
                "bool mapFilesAvailable() { return true; }"),
            "missing-block lookup opens files": (
                "MapBlock *mblock = new MapBlock();\n  " + gate,
                "MapBlock *mblock = new MapBlock();\n  if (false)"),
            "directory probe walks the tree": (
                "if (!mapFilesAvailable() || depth > 6",
                "if (depth > 6"),
            "root probe stats the volume": (
                "map_probe_diagnostics::Result result;\n  " + gate,
                "map_probe_diagnostics::Result result;\n  if (false)"),
            "root switch loads fonts and indexes": (
                "const std::string &folder) {\n  " + gate,
                "const std::string &folder) {\n  if (false)"),
            "queued storage work is admitted": (
                "  if (!mapFilesAvailable()) return false;\n"
                "  if (work == nullptr",
                "  if (work == nullptr"),
            "activation is admitted": (
                "  if (!mapFilesAvailable()) return false; // Activation",
                "  // Activation"),
            "Nearby opens the POI index": (
                "if (!mapFilesAvailable() || nearbyCoverageBlocks.empty())",
                "if (nearbyCoverageBlocks.empty())"),
        }
        for name, (old, new) in mutations.items():
            with self.subTest(name):
                result = run_renderer(
                    renderer_harness(lambda text, o=old, n=new: mutated(text, o, n)),
                    "map_storage_mutant")
                self.assertEqual(result.returncode, 42, result.stderr)


class SdOnlyMapCallerContractTests(unittest.TestCase):
    """Source contracts for the callers the harnesses cannot compile."""

    def test_map_code_takes_its_root_from_storage(self):
        files = [path for path in (ROOT / "lib/maps/src").iterdir()
                 if path.suffix in (".cpp", ".hpp", ".h") and path.name != "mapVars.h"]
        files += sorted((ROOT / "lib/map_transfer").glob("*.[ch]pp"))
        files += sorted((ROOT / "lib/map_transfer_http").glob("*.[ch]pp"))
        files += [ROOT / "lib/ble_navigation/ble_navigation.cpp",
                  ROOT / "src/main.cpp"]
        for path in files:
            with self.subTest(path.name):
                self.assertNotIn('"/sdcard', path.read_text(encoding="utf-8"))
        # mapVars.h keeps only a commented-out legacy raster path.
        maps = source("lib/maps/src/maps.cpp")
        self.assertNotIn("mapRenderFolder", maps.replace("//   sprintf(tileFile, mapRenderFolder", ""))

    def test_setup_pins_storage_before_any_owner_and_skips_maps_without_sd(self):
        main = source("src/main.cpp")
        setup = main[main.index("void setup()"):main.index("void loop()")]
        pin = setup.index("storage.pinBackendForBoot();")
        self.assertLess(setup.index("storage.initSPIFFS();"), pin)
        self.assertLess(pin, setup.index("mapView.bindMapStorageRoot(storage.mapStorageRoot());"))
        for owner in ("ride_diagnostics::begin(", "MapTransferInstaller mapInstaller(",
                      "mapTransferHttp.configure(", "mapView.initMap(", "initLVGL();"):
            self.assertLess(pin, setup.index(owner), owner)
        gate = setup.index("if (!storage.mapStorageAvailable()) {")
        recovery = setup.index("mapInstaller.recoverInterruptedActivation()")
        self.assertLess(gate, setup.index("} else {", gate))
        self.assertLess(setup.index("} else {", gate), recovery)
        self.assertIn('"map_storage_unavailable"', setup[gate:recovery])
        self.assertIn("mapTransferHttp.configure(storage.mapStorageRoot()", setup)

    def test_map_download_entry_only_validates_the_boot_card(self):
        ble = source("lib/ble_navigation/ble_navigation.cpp")
        entry = ble[ble.index("case ble_transfer::Action::EnableMap: {"):
                    ble.index("case ble_transfer::Action::EnableFirmware: {")]
        self.assertIn("storage.ensureSdMounted()", entry)
        self.assertNotIn("beginStorageTransition", entry)
        self.assertNotIn("initSD", entry)
        self.assertIn("restart", entry)
        status = ble[ble.index("readActiveMapStatusSnapshot() {"):
                     ble.index("map_transfer::ActiveMapSelection activeMap;",
                               ble.index("readActiveMapStatusSnapshot() {"))]
        self.assertLess(status.index("if (!storage.mapStorageAvailable())"),
                        status.index("MapTransferInstaller installer(storage.mapStorageRoot())"))


if __name__ == "__main__":
    unittest.main()
