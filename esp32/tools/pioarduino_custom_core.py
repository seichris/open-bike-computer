"""Pure helpers for pioarduino custom-core build workarounds."""


UPSTREAM_PM_LITERAL_MAPPING = (
    "*libesp_pm.a:pm_impl.*(.literal.esp_pm_get_configuration"
)
PHASE_7A_PM_LITERAL_MAPPING = (
    "*libesp_pm.a:pm_impl.*(.literal.esp_pm_configure "
    ".literal.esp_pm_get_configuration"
)
CORRECTED_PM_LITERAL_MAPPING = (
    f"{PHASE_7A_PM_LITERAL_MAPPING} "
    ".literal.esp_pm_register_skip_light_sleep_callback "
    ".literal.esp_pm_unregister_skip_light_sleep_callback "
    ".literal.vApplicationSleep"
)

STALE_PM_TEXT_MAPPING = (
    ".text.esp_pm_get_configuration .text.esp_pm_impl_get_mode"
)
CORRECTED_PM_TEXT_MAPPING = (
    ".text.esp_pm_get_configuration "
    ".text.esp_pm_register_skip_light_sleep_callback "
    ".text.esp_pm_unregister_skip_light_sleep_callback "
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
    if source.count(corrected) == 1:
        return source
    if source.count(corrected) != 0 or source.count(stale) != 1:
        raise ValueError(f"pioarduino {label} linker mapping has an unexpected format")
    return source.replace(stale, corrected, 1)


def correct_sections_text(sections_text: str) -> str:
    """Add the CONFIG_PM_ENABLE linker mapping missing from pinned pioarduino.

    The operation is idempotent, while an unexpected installed linker-script
    shape fails closed so a platform update cannot silently apply a bad patch.
    """
    final_pm_count = sections_text.count(CORRECTED_PM_LITERAL_MAPPING)
    phase_7a_pm_count = sections_text.count(PHASE_7A_PM_LITERAL_MAPPING)
    upstream_pm_count = sections_text.count(UPSTREAM_PM_LITERAL_MAPPING)
    if final_pm_count == 1 and upstream_pm_count == 0:
        corrected = sections_text
    elif (
        final_pm_count == 0
        and phase_7a_pm_count == 1
        and upstream_pm_count == 0
    ):
        corrected = sections_text.replace(
            PHASE_7A_PM_LITERAL_MAPPING, CORRECTED_PM_LITERAL_MAPPING, 1
        )
    elif (
        final_pm_count == 0
        and phase_7a_pm_count == 0
        and upstream_pm_count == 1
    ):
        corrected = sections_text.replace(
            UPSTREAM_PM_LITERAL_MAPPING, CORRECTED_PM_LITERAL_MAPPING, 1
        )
    else:
        raise ValueError("pioarduino esp_pm literal linker mapping has an unexpected format")

    corrected = _replace_exactly_once(
        corrected,
        STALE_PM_TEXT_MAPPING,
        CORRECTED_PM_TEXT_MAPPING,
        "esp_pm text",
    )
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
