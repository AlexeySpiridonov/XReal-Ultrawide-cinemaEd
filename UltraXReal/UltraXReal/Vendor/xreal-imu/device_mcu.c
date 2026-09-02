#include "device_mcu.h"

#include <stdio.h>
#include <string.h>
#include <libkern/OSByteOrder.h>

#include "crc32.h"
#include "device.h"
#include "hid_ids.h"
#include "hidapi.h"

#define MCU_PACKET_SIZE 64
#define MCU_HEAD 0xFD
#define MCU_REPLY_TIMEOUT_MS 250
#define MCU_REPLY_ATTEMPTS 20

enum {
    MCU_MSG_R_BRIGHTNESS = 0x03,
    MCU_MSG_W_BRIGHTNESS = 0x04,
    MCU_MSG_R_DISP_MODE  = 0x07,
    MCU_MSG_W_DISP_MODE  = 0x08,
};

struct __attribute__((__packed__)) mcu_packet_t {
    uint8_t head;
    uint32_t checksum;
    uint16_t length;
    uint64_t timestamp;
    uint16_t msgid;
    uint8_t reserved[5];
    uint8_t data[42];
};

_Static_assert(sizeof(struct mcu_packet_t) == MCU_PACKET_SIZE, "MCU packet must be 64 bytes");

static hid_device *mcu_open(void) {
    if (!device_init()) {
        return NULL;
    }

    hid_device *handle = NULL;
    struct hid_device_info *info = hid_enumerate(xreal_vendor_id, 0);
    for (struct hid_device_info *it = info; it; it = it->next) {
        const int iface = xreal_mcu_interface_id(it->product_id);
        if (iface != -1 && it->interface_number == iface) {
            handle = hid_open_path(it->path);
            if (handle) {
                break;
            }
        }
    }
    hid_free_enumeration(info);

    if (!handle) {
        fprintf(stderr, "[MCU] XReal MCU interface not found\n");
        device_exit();
    }
    return handle;
}

static void mcu_close(hid_device *handle) {
    if (handle) {
        hid_close(handle);
    }
    device_exit();
}

static bool mcu_send(hid_device *handle, uint16_t msgid, uint8_t len, const uint8_t *data) {
    struct mcu_packet_t packet;
    memset(&packet, 0, sizeof(packet));

    if (len > sizeof(packet.data)) {
        len = sizeof(packet.data);
    }

    // length covers: length(2) + timestamp(8) + msgid(2) + reserved(5) + data
    const uint16_t body_len = 17 + len;
    packet.head = MCU_HEAD;
    packet.length = OSSwapHostToLittleInt16(body_len);
    packet.timestamp = 0;
    packet.msgid = OSSwapHostToLittleInt16(msgid);
    if (len && data) {
        memcpy(packet.data, data, len);
    }
    packet.checksum = OSSwapHostToLittleInt32(
        crc32_checksum((const uint8_t *)&packet.length, body_len));

    const int written = hid_write(handle, (const uint8_t *)&packet, MCU_PACKET_SIZE);
    if (written != MCU_PACKET_SIZE) {
        fprintf(stderr, "[MCU] hid_write failed (%d)\n", written);
        return false;
    }
    return true;
}

/// Waits for a reply with the given msgid, skipping unrelated packets (heartbeats, button events).
static bool mcu_recv(hid_device *handle, uint16_t msgid, uint8_t *out, uint8_t out_len) {
    struct mcu_packet_t packet;
    for (int attempt = 0; attempt < MCU_REPLY_ATTEMPTS; attempt++) {
        const int n = hid_read_timeout(handle, (uint8_t *)&packet, MCU_PACKET_SIZE, MCU_REPLY_TIMEOUT_MS);
        if (n < 0) {
            fprintf(stderr, "[MCU] hid_read failed\n");
            return false;
        }
        if (n == 0 || packet.head != MCU_HEAD) {
            continue;
        }
        if (OSSwapLittleToHostInt16(packet.msgid) != msgid) {
            continue;
        }
        if (out && out_len) {
            memcpy(out, packet.data, out_len);
        }
        return true;
    }
    fprintf(stderr, "[MCU] no reply for msgid 0x%02x\n", msgid);
    return false;
}

static int mcu_read_byte(uint16_t read_msg) {
    hid_device *handle = mcu_open();
    if (!handle) {
        return -1;
    }

    int result = -1;
    uint8_t reply[4] = {0};
    // Reply layout: data[0] = status (0 = ok), data[1] = value.
    if (mcu_send(handle, read_msg, 0, NULL) && mcu_recv(handle, read_msg, reply, sizeof(reply))) {
        printf("[MCU] read 0x%02x -> %02x %02x %02x %02x\n", read_msg, reply[0], reply[1], reply[2], reply[3]);
        if (reply[0] == 0) {
            result = reply[1];
        }
    }

    mcu_close(handle);
    return result;
}

static bool mcu_write_byte(uint16_t write_msg, uint8_t value) {
    hid_device *handle = mcu_open();
    if (!handle) {
        return false;
    }

    bool ok = false;
    uint8_t reply[4] = {0};
    // Reply layout: data[0] = status (0 = ok).
    if (mcu_send(handle, write_msg, 1, &value) && mcu_recv(handle, write_msg, reply, sizeof(reply))) {
        printf("[MCU] write 0x%02x=%u -> %02x %02x %02x %02x\n", write_msg, value, reply[0], reply[1], reply[2], reply[3]);
        ok = (reply[0] == 0);
    }

    mcu_close(handle);
    return ok;
}

int device_mcu_get_display_mode(void) {
    return mcu_read_byte(MCU_MSG_R_DISP_MODE);
}

bool device_mcu_set_display_mode(uint8_t mode) {
    return mcu_write_byte(MCU_MSG_W_DISP_MODE, mode);
}

int device_mcu_get_brightness(void) {
    return mcu_read_byte(MCU_MSG_R_BRIGHTNESS);
}

bool device_mcu_set_brightness(uint8_t brightness) {
    return mcu_write_byte(MCU_MSG_W_BRIGHTNESS, brightness);
}
