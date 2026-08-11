"""Pure helpers for pioarduino custom-core build workarounds."""

import hashlib
from pathlib import Path


UPSTREAM_NESTED_PIO_BLOCK = '''        pio_cmd = env["PIOENV"]
        env.Execute(
            env.VerboseAction(
                (
                    '"%s" run -e ' % pio_exe_path
                    + " ".join(['"%s"' % pio_cmd])
                ),'''
VERIFIED_NESTED_PIO_BLOCK = '''        pio_cmd = env["PIOENV"]
        scons_marker = (
            Path(env.subst("$PROJECT_CORE_DIR"))
            / "packages"
            / "tool-scons"
            / ".piopm"
        )
        if scons_marker.is_symlink() or not scons_marker.is_file():
            raise RuntimeError("verified SCons package marker is missing or unsafe")
        scons_marker.write_text(
            os.environ["OPEN_BIKE_PINNED_SCONS_PIOPM"],
            encoding="utf-8",
        )
        env.Execute(
            env.VerboseAction(
                (
                    '"%s" run --project-conf "%s" -e ' % (
                        pio_exe_path,
                        os.environ["OPEN_BIKE_VERIFIED_PROJECT_CONFIG"],
                    )
                    + " ".join(['"%s"' % pio_cmd])
                ),'''

UPSTREAM_GENERATED_PROJECT_CLEANUP = '''        try:
            os.remove(str(Path(env.subst("$PROJECT_DIR")) / "dependencies.lock"))
            os.remove(str(Path(env.subst("$PROJECT_DIR")) / "CMakeLists.txt"))
        except FileNotFoundError:
            pass
        except OSError as e:
            print(f"Warning: cleanup failed: {e}")'''
VERIFIED_GENERATED_PROJECT_CLEANUP = '''        for generated_project_name in ("dependencies.lock", "CMakeLists.txt"):
            generated_project_path = (
                Path(env.subst("$PROJECT_DIR")) / generated_project_name
            )
            try:
                generated_project_path.unlink()
            except FileNotFoundError:
                pass
            except OSError as error:
                raise RuntimeError(
                    "failed to remove pioarduino generated project file: "
                    f"{generated_project_path}"
                ) from error'''

UPSTREAM_PENV_URLLIB3_REQUIREMENT = '    "urllib3": "<2",'
CORRECTED_PENV_URLLIB3_REQUIREMENT = '    "urllib3": ">=1.26,<3",'

UPSTREAM_PLATFORMIO_REQUIREMENT = (
    '    "platformio": "https://github.com/pioarduino/platformio-core/'
    'archive/refs/tags/v6.1.18.zip",'
)
VERIFIED_PLATFORMIO_REQUIREMENT = '    "pioarduino-core": "==6.1.18",'

UPSTREAM_AMBIENT_UV_FALLBACK = '''            if not os.path.isfile(uv_cmd):
                uv_cmd = "uv"'''
VERIFIED_LOCKED_UV_FALLBACK = '''            if not os.path.isfile(uv_cmd):
                uv_cmd = os.environ["OPEN_BIKE_FIRMWARE_UV"]'''
UPSTREAM_EDITABLE_ESPTOOL = '            "-e", esptool_repo_path'
VERIFIED_WHEEL_ESPTOOL = '''            "--offline", "--no-deps",
            "--no-cache",
            f"--find-links={os.environ['OPEN_BIKE_FIRMWARE_WHEELHOUSE']}",
            os.environ["OPEN_BIKE_FIRMWARE_ESPTOOL_WHEEL"]'''

UPSTREAM_EXTERNAL_UV_INSTALL = (
    '[external_uv_executable, "pip", "install", "uv>=0.1.0", '
    'f"--python={python_exe}", "--quiet"]'
)
VERIFIED_EXTERNAL_UV_INSTALL = (
    '[external_uv_executable, "pip", "install", "uv==0.12.3", '
    'f"--python={python_exe}", "--quiet", "--offline", "--no-cache", '
    'f"--find-links={os.environ[\'OPEN_BIKE_FIRMWARE_WHEELHOUSE\']}"]'
)

UPSTREAM_PENV_INSTALL_GUARD = '''    # Get the penv directory to locate uv within it
    penv_dir = os.path.dirname(os.path.dirname(python_exe))'''
VERIFIED_PENV_INSTALL_GUARD = '''    locked_uv_executable = os.environ["OPEN_BIKE_FIRMWARE_UV"]
    if external_uv_executable not in (None, locked_uv_executable):
        print("Error: locked external uv executable is required")
        return False
    if not os.path.isfile(locked_uv_executable):
        print("Error: locked external uv executable is missing")
        return False
    external_uv_executable = locked_uv_executable

    # Get the penv directory to locate uv within it
    penv_dir = str(Path(python_exe).parent.parent)'''

UPSTREAM_ROOT_INSTALL_COMMAND = '''        cmd = [
            penv_uv_executable, "pip", "install",
            f"--python={python_exe}",
            "--quiet", "--upgrade"
        ] + packages_list'''
VERIFIED_ROOT_INSTALL_COMMAND = '''        cmd = [
            penv_uv_executable, "pip", "install",
            f"--python={python_exe}",
            "--quiet", "--upgrade", "--offline", "--no-cache",
            f"--find-links={os.environ['OPEN_BIKE_FIRMWARE_WHEELHOUSE']}",
            "--requirements",
            os.environ["OPEN_BIKE_FIRMWARE_PIOARDUINO_REQUIREMENTS"],
        ]'''

UPSTREAM_INTERNET_INSTALL_GATE = "    if has_internet_connection() or github_actions:"
VERIFIED_OFFLINE_INSTALL_GATE = "    if True:  # locked wheelhouse is always available"

UPSTREAM_ESPTOOL_MATCH = '''                    "import esptool, os, sys; "
                    "expected_path = os.path.normcase(os.path.realpath(sys.argv[1])); "
                    "actual_path = os.path.normcase(os.path.realpath(os.path.dirname(esptool.__file__))); "
                    "print('MATCH' if actual_path.startswith(expected_path) else 'MISMATCH')"
                ),
                esptool_repo_path,'''
VERIFIED_ESPTOOL_MATCH = '''                    "import importlib.metadata, sys; "
                    "print('MATCH' if importlib.metadata.version('esptool') == sys.argv[1] else 'MISMATCH')"
                ),
                "5.1.0",'''

UPSTREAM_IDF_INSTALL_COMMAND = (
    '                f\'"{UV_EXE}" pip install --python "{python_exe_path}" '
    "{packages_str}\',"
)
VERIFIED_IDF_INSTALL_COMMAND = (
    '                f\'"{UV_EXE}" pip install --python "{python_exe_path}" '
    '--offline --no-cache --find-links "{os.environ["OPEN_BIKE_FIRMWARE_WHEELHOUSE"]}" '
    '--requirements "{os.environ["OPEN_BIKE_FIRMWARE_ESP_IDF_REQUIREMENTS"]}"\','
)

IDF_EXACT_REQUIREMENTS = (
    ('        "urllib3": "<2",', '        "urllib3": "==1.26.20",'),
    ('        "cryptography": "~=44.0.0",', '        "cryptography": "==44.0.3",'),
    ('        "pyparsing": ">=3.1.0,<4",', '        "pyparsing": "==3.3.2",'),
    ('        "idf-component-manager": "~=2.4",', '        "idf-component-manager": "==2.5.0",'),
    ('        "esp-idf-kconfig": "~=2.5.0"', '        "esp-idf-kconfig": "==2.5.4"'),
    ('        deps["chardet"] = ">=3.0.2,<4"', '        deps["chardet"] = "==3.0.4"'),
)


UPSTREAM_PM_LITERAL_MAPPING = (
    "*libesp_pm.a:pm_impl.*(.literal.esp_pm_get_configuration"
)
PHASE_7A_PM_LITERAL_MAPPING = (
    "*libesp_pm.a:pm_impl.*(.literal.esp_pm_configure "
    ".literal.esp_pm_get_configuration"
)
PHASE_9_ISR_PM_LITERAL_MAPPING = (
    f"{PHASE_7A_PM_LITERAL_MAPPING} "
    ".literal.esp_pm_register_skip_light_sleep_callback "
    ".literal.esp_pm_unregister_skip_light_sleep_callback "
    ".literal.vApplicationSleep"
)
CORRECTED_PM_LITERAL_MAPPING = (
    f"{PHASE_7A_PM_LITERAL_MAPPING} "
    ".literal.esp_pm_register_skip_light_sleep_callback "
    ".literal.esp_pm_unregister_skip_light_sleep_callback "
    ".literal.esp_pm_light_sleep_register_cbs "
    ".literal.esp_pm_light_sleep_unregister_cbs "
    ".literal.vApplicationSleep"
)

STALE_PM_TEXT_MAPPING = (
    ".text.esp_pm_get_configuration .text.esp_pm_impl_get_mode"
)
PHASE_9_ISR_PM_TEXT_MAPPING = (
    ".text.esp_pm_get_configuration "
    ".text.esp_pm_register_skip_light_sleep_callback "
    ".text.esp_pm_unregister_skip_light_sleep_callback "
    ".text.vApplicationSleep .text.esp_pm_impl_get_mode"
)
CORRECTED_PM_TEXT_MAPPING = (
    ".text.esp_pm_get_configuration "
    ".text.esp_pm_register_skip_light_sleep_callback "
    ".text.esp_pm_unregister_skip_light_sleep_callback "
    ".text.esp_pm_light_sleep_register_cbs "
    ".text.esp_pm_light_sleep_unregister_cbs "
    ".text.vApplicationSleep .text.esp_pm_impl_get_mode"
)

STALE_FREERTOS_TICKLESS_LITERAL_MAPPING = (
    ".literal.xTaskResumeFromISR .text .text.__getreent"
)
CORRECTED_FREERTOS_TICKLESS_LITERAL_MAPPING = (
    ".literal.xTaskResumeFromISR .literal.prvGetExpectedIdleTime "
    ".literal.vTaskStepTick .text .text.__getreent"
)

STALE_FREERTOS_TICKLESS_TEXT_MAPPING = (
    ".text.xTaskResumeFromISR .text.xTimerCreateTimerTask)"
)
CORRECTED_FREERTOS_TICKLESS_TEXT_MAPPING = (
    ".text.xTaskResumeFromISR .text.prvGetExpectedIdleTime "
    ".text.vTaskStepTick .text.xTimerCreateTimerTask)"
)


def _replace_exactly_once(source: str, stale: str, corrected: str, label: str) -> str:
    stale_count = source.count(stale)
    corrected_count = source.count(corrected)
    if corrected_count == 1 and stale_count == 0:
        return source
    if corrected_count != 0 or stale_count != 1:
        raise ValueError(f"pioarduino {label} has an unexpected format")
    return source.replace(stale, corrected, 1)


def correct_nested_pio_command(source: str) -> str:
    """Force pioarduino's recursive build through the verified project config."""
    return _replace_exactly_once(
        source,
        UPSTREAM_NESTED_PIO_BLOCK,
        VERIFIED_NESTED_PIO_BLOCK,
        "nested PlatformIO command",
    )


def correct_generated_project_cleanup(source: str) -> str:
    """Remove each pioarduino project artifact independently and fail closed.

    The pinned builder puts both files in the repository root before its
    recursive Arduino pass. Its shared ``try`` skips ``CMakeLists.txt`` when
    ``dependencies.lock`` is already absent, which makes the verified nested
    prebuild see a dirty source tree. Treat each generated path independently
    so every supported diagnostic profile reaches the recursive build with the
    exact clean Git identity.
    """
    return _replace_exactly_once(
        source,
        UPSTREAM_GENERATED_PROJECT_CLEANUP,
        VERIFIED_GENERATED_PROJECT_CLEANUP,
        "generated project cleanup",
    )


def pioarduino_transform_source_sha256() -> str:
    """Identify the exact repository-owned pre-execution transform source."""
    source = Path(__file__)
    if source.is_symlink() or not source.is_file():
        raise ValueError("pioarduino transform source is missing or unsafe")
    try:
        return hashlib.sha256(source.read_bytes()).hexdigest()
    except OSError as error:
        raise ValueError("could not hash pioarduino transform source") from error


def verified_transform_marker_matches(
    marker: object,
    platform_archive_sha256: str,
    runtime_provenance: object,
    transform_source_sha256: str,
) -> bool:
    """Validate the complete installed-platform transform identity."""
    if not isinstance(marker, dict):
        return False
    platform_tree_sha256 = marker.get("platformTreeSha256")
    return (
        set(marker)
        == {
            "schema",
            "platformArchiveSha256",
            "runtimeProvenance",
            "transformSourceSha256",
            "platformTreeSha256",
        }
        and marker.get("schema") == 2
        and marker.get("platformArchiveSha256") == platform_archive_sha256
        and marker.get("runtimeProvenance") == runtime_provenance
        and marker.get("transformSourceSha256") == transform_source_sha256
        and isinstance(platform_tree_sha256, str)
        and len(platform_tree_sha256) == 64
        and all(character in "0123456789abcdef" for character in platform_tree_sha256)
    )


def correct_penv_setup_text(source: str) -> str:
    """Keep pioarduino's root HTTP dependency stable across nested passes.

    The pinned platform requests urllib3<2, while a later ``--upgrade`` pass
    resolves the root requests 2.x stack back to urllib3 2.x. Using requests'
    supported range lets both passes accept the same installed dependency
    instead of alternately replacing it and invalidating the core attestation.
    """
    corrected = _replace_exactly_once(
        source,
        UPSTREAM_PENV_URLLIB3_REQUIREMENT,
        CORRECTED_PENV_URLLIB3_REQUIREMENT,
        "Python resolver urllib3 requirement",
    )
    for stale, final, label in (
        (
            UPSTREAM_PLATFORMIO_REQUIREMENT,
            VERIFIED_PLATFORMIO_REQUIREMENT,
            "PlatformIO wheel requirement",
        ),
        (
            UPSTREAM_EXTERNAL_UV_INSTALL,
            VERIFIED_EXTERNAL_UV_INSTALL,
            "locked uv installation",
        ),
        (
            UPSTREAM_PENV_INSTALL_GUARD,
            VERIFIED_PENV_INSTALL_GUARD,
            "locked uv guard",
        ),
        (
            UPSTREAM_ROOT_INSTALL_COMMAND,
            VERIFIED_ROOT_INSTALL_COMMAND,
            "root wheelhouse installation",
        ),
        (
            UPSTREAM_INTERNET_INSTALL_GATE,
            VERIFIED_OFFLINE_INSTALL_GATE,
            "offline installation gate",
        ),
    ):
        corrected = _replace_exactly_once(corrected, stale, final, label)
    ambient_count = corrected.count(UPSTREAM_AMBIENT_UV_FALLBACK)
    locked_count = corrected.count(VERIFIED_LOCKED_UV_FALLBACK)
    if ambient_count == 2 and locked_count == 0:
        corrected = corrected.replace(
            UPSTREAM_AMBIENT_UV_FALLBACK, VERIFIED_LOCKED_UV_FALLBACK
        )
    elif ambient_count != 0 or locked_count != 2:
        raise ValueError("pioarduino ambient uv fallback has an unexpected format")
    editable_count = corrected.count(UPSTREAM_EDITABLE_ESPTOOL)
    wheel_count = corrected.count(VERIFIED_WHEEL_ESPTOOL)
    if editable_count == 2 and wheel_count == 0:
        corrected = corrected.replace(
            UPSTREAM_EDITABLE_ESPTOOL, VERIFIED_WHEEL_ESPTOOL
        )
    elif editable_count != 0 or wheel_count != 2:
        raise ValueError("pioarduino editable esptool install has an unexpected format")
    upstream_match_count = corrected.count(UPSTREAM_ESPTOOL_MATCH)
    verified_match_count = corrected.count(VERIFIED_ESPTOOL_MATCH)
    if upstream_match_count == 2 and verified_match_count == 0:
        corrected = corrected.replace(UPSTREAM_ESPTOOL_MATCH, VERIFIED_ESPTOOL_MATCH)
    elif upstream_match_count != 0 or verified_match_count != 2:
        raise ValueError("pioarduino esptool identity check has an unexpected format")
    return corrected


def correct_espidf_setup_text(source: str) -> str:
    """Force the ESP-IDF virtual environment through the locked wheelhouse."""
    corrected = source
    for stale, final in IDF_EXACT_REQUIREMENTS:
        corrected = _replace_exactly_once(
            corrected, stale, final, "ESP-IDF exact dependency requirement"
        )
    return _replace_exactly_once(
        corrected,
        UPSTREAM_IDF_INSTALL_COMMAND,
        VERIFIED_IDF_INSTALL_COMMAND,
        "ESP-IDF offline wheelhouse installation",
    )


def correct_espidf_text(source: str) -> str:
    """Apply every verified transform to pioarduino's ESP-IDF builder."""
    return correct_generated_project_cleanup(
        correct_espidf_setup_text(correct_nested_pio_command(source))
    )


def correct_sections_text(sections_text: str) -> str:
    """Add the CONFIG_PM_ENABLE linker mapping missing from pinned pioarduino.

    The operation is idempotent, while an unexpected installed linker-script
    shape fails closed so a platform update cannot silently apply a bad patch.
    """
    final_pm_count = sections_text.count(CORRECTED_PM_LITERAL_MAPPING)
    phase_9_isr_pm_count = sections_text.count(PHASE_9_ISR_PM_LITERAL_MAPPING)
    phase_7a_pm_count = sections_text.count(PHASE_7A_PM_LITERAL_MAPPING)
    upstream_pm_count = sections_text.count(UPSTREAM_PM_LITERAL_MAPPING)
    if (
        final_pm_count == 1
        and phase_9_isr_pm_count == 0
        and phase_7a_pm_count == 1
        and upstream_pm_count == 0
    ):
        corrected = sections_text
    elif (
        final_pm_count == 0
        and phase_9_isr_pm_count == 1
        and phase_7a_pm_count == 1
        and upstream_pm_count == 0
    ):
        corrected = sections_text.replace(
            PHASE_9_ISR_PM_LITERAL_MAPPING, CORRECTED_PM_LITERAL_MAPPING, 1
        )
    elif (
        final_pm_count == 0
        and phase_9_isr_pm_count == 0
        and phase_7a_pm_count == 1
        and upstream_pm_count == 0
    ):
        corrected = sections_text.replace(
            PHASE_7A_PM_LITERAL_MAPPING, CORRECTED_PM_LITERAL_MAPPING, 1
        )
    elif (
        final_pm_count == 0
        and phase_9_isr_pm_count == 0
        and phase_7a_pm_count == 0
        and upstream_pm_count == 1
    ):
        corrected = sections_text.replace(
            UPSTREAM_PM_LITERAL_MAPPING, CORRECTED_PM_LITERAL_MAPPING, 1
        )
    else:
        raise ValueError("pioarduino esp_pm literal linker mapping has an unexpected format")

    final_pm_text_count = corrected.count(CORRECTED_PM_TEXT_MAPPING)
    phase_9_isr_pm_text_count = corrected.count(PHASE_9_ISR_PM_TEXT_MAPPING)
    stale_pm_text_count = corrected.count(STALE_PM_TEXT_MAPPING)
    if (
        final_pm_text_count == 1
        and phase_9_isr_pm_text_count == 0
        and stale_pm_text_count == 0
    ):
        pass
    elif (
        final_pm_text_count == 0
        and phase_9_isr_pm_text_count == 1
        and stale_pm_text_count == 0
    ):
        corrected = corrected.replace(
            PHASE_9_ISR_PM_TEXT_MAPPING, CORRECTED_PM_TEXT_MAPPING, 1
        )
    elif (
        final_pm_text_count == 0
        and phase_9_isr_pm_text_count == 0
        and stale_pm_text_count == 1
    ):
        corrected = corrected.replace(
            STALE_PM_TEXT_MAPPING, CORRECTED_PM_TEXT_MAPPING, 1
        )
    else:
        raise ValueError("pioarduino esp_pm text linker mapping has an unexpected format")

    corrected = _replace_exactly_once(
        corrected,
        STALE_FREERTOS_TICKLESS_LITERAL_MAPPING,
        CORRECTED_FREERTOS_TICKLESS_LITERAL_MAPPING,
        "FreeRTOS tickless literal",
    )
    return _replace_exactly_once(
        corrected,
        STALE_FREERTOS_TICKLESS_TEXT_MAPPING,
        CORRECTED_FREERTOS_TICKLESS_TEXT_MAPPING,
        "FreeRTOS tickless text",
    )
