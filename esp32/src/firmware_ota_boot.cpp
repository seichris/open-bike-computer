// Arduino's default hook confirms a pending image before setup(). The
// application owns confirmation after initialization of the usable device.
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include <sdkconfig.h>
#if !CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE || !CONFIG_APP_ROLLBACK_ENABLE
#error "Waveshare OTA requires bootloader rollback and deferred app confirmation"
#endif
extern "C" bool verifyRollbackLater(void) { return true; }
#endif
