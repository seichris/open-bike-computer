#pragma once

#ifndef USB_RECOVERY_STATUS
#define USB_RECOVERY_STATUS 0
#endif

namespace usb_recovery_status {
#if USB_RECOVERY_STATUS
void begin();
void process();
#else
inline void begin() {}
inline void process() {}
#endif
} // namespace usb_recovery_status
