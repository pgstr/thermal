#include "cfanwrite.h"

#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

// Same AppleSMC user-client ABI as Sources/CSMC (verified on M5 Pro in M0/M1).
#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
    char result; char status; char data8; uint32_t data32; unsigned char bytes[32];
} SMCParam;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(unsigned char)s[0] << 24) | ((uint32_t)(unsigned char)s[1] << 16) |
           ((uint32_t)(unsigned char)s[2] << 8) | (uint32_t)(unsigned char)s[3];
}

static kern_return_t call(uint32_t conn, SMCParam *in, SMCParam *out) {
    size_t sz = sizeof(SMCParam);
    return IOConnectCallStructMethod((io_connect_t)conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), out, &sz);
}

uint32_t cfw_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? (uint32_t)conn : 0;
}

void cfw_close(uint32_t conn) { if (conn) IOServiceClose((io_connect_t)conn); }

static int keyinfo(uint32_t conn, const char *key, uint32_t *size) {
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(key); in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result) return (unsigned char)out.result;
    *size = out.keyInfo.dataSize;
    return 0;
}

static int read_bytes(uint32_t conn, const char *key, unsigned char *buf, uint32_t want) {
    uint32_t size = 0;
    int rc = keyinfo(conn, key, &size);
    if (rc) return rc;
    if (size != want) return -3;
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(key); in.keyInfo.dataSize = size; in.data8 = SMC_CMD_READ_BYTES;
    kern_return_t kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result) return (unsigned char)out.result;
    memcpy(buf, out.bytes, size);
    return 0;
}

int cfw_read_float(uint32_t conn, const char *key, float *out) {
    unsigned char b[4];
    int rc = read_bytes(conn, key, b, 4);
    if (!rc) memcpy(out, b, 4);   // little-endian IEEE float on Apple Silicon
    return rc;
}

int cfw_read_u8(uint32_t conn, const char *key, uint8_t *out) {
    return read_bytes(conn, key, out, 1);
}

static bool allowlisted(const char *key) {
    return strlen(key) == 4 && key[0] == 'F' && key[1] >= '0' && key[1] <= '9' &&
           (strcmp(key + 2, "md") == 0 || strcmp(key + 2, "Tg") == 0);
}

static int write_bytes(uint32_t conn, const char *key, const unsigned char *data, uint32_t len) {
    if (!allowlisted(key)) return -1;
    uint32_t size = 0;
    if (keyinfo(conn, key, &size)) return -2;
    if (size != len) return -3;
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(key); in.data8 = SMC_CMD_WRITE_BYTES; in.keyInfo.dataSize = size;
    memcpy(in.bytes, data, len);
    kern_return_t kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS) return kr;
    return (unsigned char)out.result;
}

int cfw_write_mode(uint32_t conn, int fan, uint8_t manual) {
    if (fan < 0 || fan > 9) return -1;
    char key[5]; snprintf(key, sizeof key, "F%dmd", fan);
    uint8_t v = manual ? 1 : 0;
    return write_bytes(conn, key, &v, 1);
}

int cfw_write_target(uint32_t conn, int fan, float rpm) {
    if (fan < 0 || fan > 9) return -1;
    char key[5]; snprintf(key, sizeof key, "F%dTg", fan);
    unsigned char b[4]; memcpy(b, &rpm, 4);
    return write_bytes(conn, key, b, 4);
}
