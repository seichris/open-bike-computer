"""Pure helpers for pioarduino custom-core build workarounds."""


STALE_PM_LITERAL_MAPPING = (
    "*libesp_pm.a:pm_impl.*(.literal.esp_pm_get_configuration"
)
CORRECTED_PM_LITERAL_MAPPING = (
    "*libesp_pm.a:pm_impl.*(.literal.esp_pm_configure "
    ".literal.esp_pm_get_configuration"
)


def correct_sections_text(sections_text: str) -> str:
    """Add the CONFIG_PM_ENABLE linker mapping missing from pinned pioarduino.

    The operation is idempotent, while an unexpected installed linker-script
    shape fails closed so a platform update cannot silently apply a bad patch.
    """
    corrected_count = sections_text.count(CORRECTED_PM_LITERAL_MAPPING)
    stale_count = sections_text.count(STALE_PM_LITERAL_MAPPING)
    if corrected_count == 1 and stale_count == 0:
        return sections_text
    if corrected_count != 0 or stale_count != 1:
        raise ValueError("pioarduino esp_pm linker mapping has an unexpected format")
    return sections_text.replace(
        STALE_PM_LITERAL_MAPPING,
        CORRECTED_PM_LITERAL_MAPPING,
        1,
    )
