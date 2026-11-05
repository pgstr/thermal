#include "csmc.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdlib.h>
#include <string.h>

// ---------- AppleSMC user-client ABI (same layout as smcprobe/smcprobe.c) ----------

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_INDEX 8
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
static void unfourcc(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0;
}

static kern_return_t call(uint32_t conn, SMCParam *in, SMCParam *out) {
    size_t sz = sizeof(SMCParam);
    return IOConnectCallStructMethod((io_connect_t)conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), out, &sz);
}

uint32_t csmc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? (uint32_t)conn : 0;
}

void csmc_close(uint32_t conn) { if (conn) IOServiceClose((io_connect_t)conn); }

int csmc_read(uint32_t conn, const char *key, csmc_value *v) {
    memset(v, 0, sizeof *v);
    strncpy(v->key, key, 4);
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(v->key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result) return (unsigned char)out.result;
    uint32_t size = out.keyInfo.dataSize > 32 ? 32 : out.keyInfo.dataSize;
    unfourcc(out.keyInfo.dataType, v->type);

    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(v->key);
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result) return (unsigned char)out.result;
    v->size = size;
    memcpy(v->bytes, out.bytes, size);
    return 0;
}

int csmc_key_count(uint32_t conn, uint32_t *count) {
    csmc_value v;
    int rc = csmc_read(conn, "#KEY", &v);
    if (rc) return rc;
    if (v.size < 4) return -1;
    // #KEY is the one big-endian integer on Apple Silicon.
    *count = ((uint32_t)v.bytes[0] << 24) | ((uint32_t)v.bytes[1] << 16) | ((uint32_t)v.bytes[2] << 8) | v.bytes[3];
    return 0;
}

int csmc_key_at(uint32_t conn, uint32_t index, char out_key[5]) {
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    kern_return_t kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result) return (unsigned char)out.result;
    unfourcc(out.key, out_key);
    return 0;
}

// ---------- HID temperature sensors ----------

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);

#define kIOHIDEventTypeTemperature 15

struct csmc_hid {
    IOHIDEventSystemClientRef client;
    CFArrayRef services;
    int count;
    char (*names)[64];      // cached "Product" per service (static, so read once)
    uint64_t *locations;    // cached "LocationID"
    bool *enabled;          // caller can disable channels that never return plausible values
};

csmc_hid *csmc_hid_create(void) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return NULL;
    int page = 0xff00, usage = 5; // AppleVendor / TemperatureSensor
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *ks[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vs[] = { p, u };
    CFDictionaryRef match = CFDictionaryCreate(NULL, ks, vs, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match); CFRelease(p); CFRelease(u);

    csmc_hid *h = calloc(1, sizeof *h);
    h->client = client;
    h->services = IOHIDEventSystemClientCopyServices(client);
    h->count = h->services ? (int)CFArrayGetCount(h->services) : 0;
    h->names = calloc(h->count ? h->count : 1, sizeof *h->names);
    h->locations = calloc(h->count ? h->count : 1, sizeof *h->locations);
    h->enabled = calloc(h->count ? h->count : 1, sizeof *h->enabled);
    for (int i = 0; i < h->count; i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(h->services, i);
        CFTypeRef name = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        if (name && CFGetTypeID(name) == CFStringGetTypeID())
            CFStringGetCString(name, h->names[i], sizeof h->names[i], kCFStringEncodingUTF8);
        else
            strcpy(h->names[i], "(unnamed)");
        if (name) CFRelease(name);
        CFTypeRef loc = IOHIDServiceClientCopyProperty(s, CFSTR("LocationID"));
        if (loc && CFGetTypeID(loc) == CFNumberGetTypeID()) {
            long long l = 0; CFNumberGetValue(loc, kCFNumberLongLongType, &l); h->locations[i] = (uint64_t)l;
        }
        if (loc) CFRelease(loc);
        h->enabled[i] = true;
    }
    return h;
}

void csmc_hid_destroy(csmc_hid *h) {
    if (!h) return;
    if (h->services) CFRelease(h->services);
    if (h->client) CFRelease(h->client);
    free(h->names); free(h->locations); free(h->enabled);
    free(h);
}

int csmc_hid_count(csmc_hid *h) { return h ? h->count : 0; }

void csmc_hid_set_enabled(csmc_hid *h, int index, bool enabled) {
    if (h && index >= 0 && index < h->count) h->enabled[index] = enabled;
}

int csmc_hid_read(csmc_hid *h, csmc_hid_temp *out, int max) {
    if (!h || !h->services) return 0;
    int got = 0;
    for (int i = 0; i < h->count && got < max; i++) {
        if (!h->enabled[i]) continue;
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(h->services, i);
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(s, kIOHIDEventTypeTemperature, 0, 0);
        if (!ev) continue;
        csmc_hid_temp *t = &out[got++];
        t->index = i;
        t->celsius = IOHIDEventGetFloatValue(ev, kIOHIDEventTypeTemperature << 16);
        CFRelease(ev);
        memcpy(t->name, h->names[i], sizeof t->name);
        t->location = h->locations[i];
    }
    return got;
}
