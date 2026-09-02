#pragma once
//
// XReal Air MCU control over USB HID: display mode (2D / side-by-side 3D) and brightness.
// Protocol follows the open xrealAirLinuxDriver (device_mcu.c). Every call opens the
// MCU HID interface, talks to it and closes it again, so it can be used alongside the IMU.
//

#ifndef __cplusplus
#include <stdbool.h>
#include <stdint.h>
#else
#include <cstdint>
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum device_mcu_display_mode_t {
    DEVICE_MCU_DISPLAY_MODE_1920x1080x60  = 0x1,
    DEVICE_MCU_DISPLAY_MODE_3840x1080x60  = 0x3,  // side-by-side 3D
    DEVICE_MCU_DISPLAY_MODE_1920x1080x72  = 0x4,
    DEVICE_MCU_DISPLAY_MODE_1920x1080x90  = 0x5,
    DEVICE_MCU_DISPLAY_MODE_3840x1080x72  = 0x8,  // side-by-side 3D
    DEVICE_MCU_DISPLAY_MODE_3840x1080x90  = 0x9,  // side-by-side 3D
    DEVICE_MCU_DISPLAY_MODE_1920x1080x120 = 0xA,
    DEVICE_MCU_DISPLAY_MODE_3840x1080x120 = 0xB,  // side-by-side 3D
};

/// Current display mode as reported by the glasses, or -1 on failure.
int device_mcu_get_display_mode(void);

/// Asks the glasses to switch display mode. Returns true when the glasses replied to the command.
bool device_mcu_set_display_mode(uint8_t mode);

/// Current brightness (0..7), or -1 on failure.
int device_mcu_get_brightness(void);

/// Sets brightness (0..7). Returns true when the glasses replied to the command.
bool device_mcu_set_brightness(uint8_t brightness);

#ifdef __cplusplus
}
#endif
