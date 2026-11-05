// smcprobe — READ-ONLY probe of battery, SMC keys and HID temperature sensors.
//
// There is deliberately no write path in this file: it only ever issues the
// SMC "read key info", "read by index" and "read bytes" commands.
//
// Build:  clang -O2 -Wall -o smcprobe smcprobe.c -framework IOKit -framework CoreFoundation
//
// Usage:
//   ./smcprobe                 summary (battery, known control keys, CH*/F*/TB* families, HID sensors)
//   ./smcprobe dump            every SMC key: KEY TYPE SIZE HEX DECODED   (diff two dumps!)
//   ./smcprobe read KEY ...    read specific keys
//   ./smcprobe watch KEY ...   re-read keys every second, print only on change (Ctrl-C to stop)
//   ./smcprobe hid             HID temperature sensors only

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

// ---------- SMC user-client structures (classic AppleSMC ABI) ----------

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    unsigned char bytes[32];
} SMCParam;

typedef struct {
    char key[5];
    char type[5];
    uint32_t size;
    unsigned char bytes[32];
    bool ok;
    int err; // SMC result code or IOKit error when !ok
} SMCVal;

static io_connect_t g_conn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(unsigned char)s[0] << 24) | ((uint32_t)(unsigned char)s[1] << 16) |
           ((uint32_t)(unsigned char)s[2] << 8) | (uint32_t)(unsigned char)s[3];
}
static void unfourcc(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0;
}

static kern_return_t smc_call(SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), out, &outSize);
}

static bool smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) { fprintf(stderr, "AppleSMC service not found\n"); return false; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "IOServiceOpen(AppleSMC) failed: 0x%x\n", kr); return false; }
    return true;
}

static SMCVal smc_read(const char *key) {
    SMCVal v; memset(&v, 0, sizeof v);
    strncpy(v.key, key, 4);
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(v.key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) { v.err = kr; return v; }
    if (out.result != 0) { v.err = (unsigned char)out.result; return v; }
    v.size = out.keyInfo.dataSize;
    unfourcc(out.keyInfo.dataType, v.type);
    if (v.size > 32) v.size = 32;

    memset(&in, 0, sizeof in);
    in.key = fourcc(v.key);
    in.keyInfo.dataSize = v.size;
    in.data8 = SMC_CMD_READ_BYTES;
    memset(&out, 0, sizeof out);
    kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) { v.err = kr; return v; }
    if (out.result != 0) { v.err = (unsigned char)out.result; return v; }
    memcpy(v.bytes, out.bytes, v.size);
    v.ok = true;
    return v;
}

static uint32_t smc_key_count(void) {
    SMCVal v = smc_read("#KEY");
    if (!v.ok || v.size < 4) return 0;
    return ((uint32_t)v.bytes[0] << 24) | ((uint32_t)v.bytes[1] << 16) | ((uint32_t)v.bytes[2] << 8) | v.bytes[3];
}

static bool smc_key_at(uint32_t idx, char out_key[5]) {
    SMCParam in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = idx;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return false;
    unfourcc(out.key, out_key);
    return true;
}

// ---------- value formatting ----------

static void fmt_hex(const SMCVal *v, char *buf, size_t n) {
    buf[0] = 0;
    size_t pos = 0;
    for (uint32_t i = 0; i < v->size && pos + 3 < n; i++) pos += snprintf(buf + pos, n - pos, "%02x", v->bytes[i]);
}

static uint64_t be(const unsigned char *b, int n) { uint64_t r = 0; for (int i = 0; i < n; i++) r = (r << 8) | b[i]; return r; }
static uint64_t le(const unsigned char *b, int n) { uint64_t r = 0; for (int i = n - 1; i >= 0; i--) r = (r << 8) | b[i]; return r; }

static void fmt_decoded(const SMCVal *v, char *buf, size_t n) {
    const char *t = v->type;
    const unsigned char *b = v->bytes;
    buf[0] = 0;
    if (!strcmp(t, "flt ") && v->size == 4) { float f; memcpy(&f, b, 4); snprintf(buf, n, "%.3f", f); }
    else if (!strcmp(t, "ui8 ") && v->size >= 1) snprintf(buf, n, "%u", b[0]);
    // Apple Silicon SMC stores integers little-endian (verified: B0DC=6249 = DesignCapacity).
    // Only the legacy #KEY counter is big-endian (see smc_key_count).
    else if (!strcmp(t, "ui16") && v->size >= 2) snprintf(buf, n, "%llu", le(b, 2));
    else if (!strcmp(t, "ui32") && v->size >= 4) snprintf(buf, n, "%llu", le(b, 4));
    else if (!strcmp(t, "ui64") && v->size >= 8) snprintf(buf, n, "%llu", le(b, 8));
    else if (!strcmp(t, "si8 ") && v->size >= 1) snprintf(buf, n, "%d", (int8_t)b[0]);
    else if (!strcmp(t, "si16") && v->size >= 2) snprintf(buf, n, "%d", (int16_t)le(b, 2));
    else if (!strcmp(t, "si32") && v->size >= 4) snprintf(buf, n, "%d", (int32_t)le(b, 4));
    else if (!strcmp(t, "si64") && v->size >= 8) snprintf(buf, n, "%lld", (int64_t)le(b, 8));
    else if (!strcmp(t, "sp78") && v->size >= 2) snprintf(buf, n, "%.2f", (int16_t)be(b, 2) / 256.0);
    else if (!strcmp(t, "fpe2") && v->size >= 2) snprintf(buf, n, "%.2f", be(b, 2) / 4.0);
    else if (!strcmp(t, "ioft") && v->size >= 8) snprintf(buf, n, "%.3f", le(b, 8) / 65536.0);
    else if (!strcmp(t, "flag") && v->size >= 1) snprintf(buf, n, "%s", b[0] ? "true" : "false");
    else if (!strncmp(t, "ch8", 3)) {
        size_t k = 0;
        for (uint32_t i = 0; i < v->size && k + 1 < n; i++) buf[k++] = (b[i] >= 32 && b[i] < 127) ? (char)b[i] : '.';
        buf[k] = 0;
    }
}

static void print_val(const SMCVal *v, const char *note) {
    char hex[80], dec[64];
    if (!v->ok) {
        printf("  %-4s  %-28s%s%s\n", v->key, v->err == 0x84 ? "(not present)" : "(read error)",
               note ? "  " : "", note ? note : "");
        return;
    }
    fmt_hex(v, hex, sizeof hex);
    fmt_decoded(v, dec, sizeof dec);
    printf("  %-4s  %-4s %2u  %-20s %-12s%s%s\n", v->key, v->type, v->size, hex, dec,
           note ? "  " : "", note ? note : "");
}

// ---------- key enumeration ----------

typedef struct { char key[5]; } KeyName;

static KeyName *all_keys(uint32_t *count) {
    uint32_t n = smc_key_count();
    KeyName *keys = calloc(n ? n : 1, sizeof(KeyName));
    uint32_t got = 0;
    for (uint32_t i = 0; i < n; i++)
        if (smc_key_at(i, keys[got].key)) got++;
    *count = got;
    return keys;
}

// ---------- battery (IORegistry, no SMC) ----------

static void print_cf_number(CFDictionaryRef d, const char *name, double scale, const char *unit) {
    CFStringRef k = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(d, k);
    if (!v) { // many fields moved into the nested BatteryData dict on newer macOS
        CFDictionaryRef bd = CFDictionaryGetValue(d, CFSTR("BatteryData"));
        if (bd && CFGetTypeID(bd) == CFDictionaryGetTypeID()) v = CFDictionaryGetValue(bd, k);
    }
    CFRelease(k);
    if (!v) { printf("  %-28s (absent)\n", name); return; }
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        long long x = 0; CFNumberGetValue(v, kCFNumberLongLongType, &x);
        if (scale != 1.0) printf("  %-28s %.2f %s\n", name, x * scale, unit);
        else printf("  %-28s %lld %s\n", name, x, unit);
    } else if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
        printf("  %-28s %s\n", name, CFBooleanGetValue(v) ? "Yes" : "No");
    }
}

static void print_battery(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!svc) { printf("  AppleSmartBattery not found\n"); return; }
    CFMutableDictionaryRef props = NULL;
    IORegistryEntryCreateCFProperties(svc, &props, NULL, 0);
    IOObjectRelease(svc);
    if (!props) return;
    print_cf_number(props, "CurrentCapacity", 1, "%");
    print_cf_number(props, "ExternalConnected", 1, "");
    print_cf_number(props, "IsCharging", 1, "");
    print_cf_number(props, "FullyCharged", 1, "");
    // Battery temperature is not reliably in IORegistry on macOS 27; use SMC TB0T/TB1T/TB2T instead.
    print_cf_number(props, "Voltage", 0.001, "V");
    print_cf_number(props, "Amperage", 1, "mA");
    print_cf_number(props, "InstantAmperage", 1, "mA");
    print_cf_number(props, "CycleCount", 1, "");
    print_cf_number(props, "DesignCapacity", 1, "mAh");
    print_cf_number(props, "AppleRawMaxCapacity", 1, "mAh");
    print_cf_number(props, "NominalChargeCapacity", 1, "mAh");

    CFDictionaryRef lifetime = CFDictionaryGetValue(props, CFSTR("LifetimeData"));
    if (!lifetime) {
        CFDictionaryRef bd = CFDictionaryGetValue(props, CFSTR("BatteryData"));
        if (bd && CFGetTypeID(bd) == CFDictionaryGetTypeID()) lifetime = CFDictionaryGetValue(bd, CFSTR("LifetimeData"));
    }
    if (lifetime && CFGetTypeID(lifetime) == CFDictionaryGetTypeID()) {
        printf("  LifetimeData:\n");
        print_cf_number(lifetime, "MaximumTemperature", 1, "C");
        print_cf_number(lifetime, "MinimumTemperature", 1, "C");
        print_cf_number(lifetime, "AverageTemperature", 0.1, "C");
    }

    CFDictionaryRef charger = CFDictionaryGetValue(props, CFSTR("ChargerData"));
    if (charger && CFGetTypeID(charger) == CFDictionaryGetTypeID()) {
        printf("  ChargerData:\n");
        print_cf_number(charger, "IsCharging", 1, "");
        print_cf_number(charger, "NotChargingReason", 1, "(0 = none; nonzero = inhibited/limited)");
        print_cf_number(charger, "SlowChargingReason", 1, "");
        print_cf_number(charger, "TimeChargingThermallyLimited", 1, "s");
        print_cf_number(charger, "ChargerInhibitReason", 1, "");
    }
    CFDictionaryRef adapter = CFDictionaryGetValue(props, CFSTR("AdapterDetails"));
    if (adapter && CFGetTypeID(adapter) == CFDictionaryGetTypeID()) {
        printf("  AdapterDetails:\n");
        print_cf_number(adapter, "Watts", 1, "W");
    }
    CFRelease(props);
}

// ---------- HID temperature sensors (private IOKit API, read-only) ----------

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

typedef struct { char name[96]; double c; } HidTemp;
static int cmp_hid(const void *a, const void *b) { return strcmp(((const HidTemp *)a)->name, ((const HidTemp *)b)->name); }

static void print_hid(void) {
    IOHIDEventSystemClientRef sys = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!sys) { printf("  IOHIDEventSystemClientCreate failed\n"); return; }
    int page = 0xff00, usage = 5;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *ks[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vs[] = { p, u };
    CFDictionaryRef match = CFDictionaryCreate(NULL, ks, vs, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(sys, match);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(sys);
    CFIndex n = services ? CFArrayGetCount(services) : 0;
    HidTemp *list = calloc(n ? n : 1, sizeof(HidTemp));
    int got = 0, skipped = 0;
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef name = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(s, kIOHIDEventTypeTemperature, 0, 0);
        double c = ev ? IOHIDEventGetFloatValue(ev, kIOHIDEventTypeTemperature << 16) : 0;
        if (ev && (c < -40 || c > 150)) { CFRelease(ev); ev = NULL; skipped++; } // uncalibrated/unused channels
        if (ev) {
            list[got].c = IOHIDEventGetFloatValue(ev, kIOHIDEventTypeTemperature << 16);
            if (name && CFGetTypeID(name) == CFStringGetTypeID())
                CFStringGetCString(name, list[got].name, sizeof list[got].name, kCFStringEncodingUTF8);
            else strcpy(list[got].name, "(unnamed)");
            got++;
            CFRelease(ev);
        }
        if (name) CFRelease(name);
    }
    qsort(list, got, sizeof(HidTemp), cmp_hid);
    printf("  %d sensors (%d implausible readings hidden)\n", got, skipped);
    for (int i = 0; i < got; i++) printf("  %-40s %6.1f C\n", list[i].name, list[i].c);
    free(list);
    if (services) CFRelease(services);
    CFRelease(match); CFRelease(p); CFRelease(u); CFRelease(sys);
}

// ---------- known control keys (from M1–M4 era tools; to be verified on M5) ----------

typedef struct { const char *key; const char *note; } Known;
static const Known kKnown[] = {
    { "CHTE", "charging inhibit (macOS 15+ / newer fw), used by AlDente/battery" },
    { "CH0B", "charging inhibit (legacy)" },
    { "CH0C", "charging inhibit (legacy)" },
    { "CHIE", "adapter disable / force discharge (newer fw)" },
    { "CH0I", "adapter disable / force discharge (legacy)" },
    { "CH0J", "adapter related (legacy)" },
    { "CH0K", "charger related (legacy)" },
    { "CHWA", "80% charge-limit flag (some Apple Silicon fw)" },
    { "BCLM", "battery charge level max (Intel-era)" },
    { "ACLC", "MagSafe LED control" },
    { "AC-W", "adapter wattage" },
    { "B0Te", "battery temp?" },
    { "TB0T", "battery temp sensor 0" },
    { "TB1T", "battery temp sensor 1" },
    { "TB2T", "battery temp sensor 2" },
    { "FNum", "number of fans" },
    { "Ftst", "fan test/force mode (needed for manual fan on M1–M3)" },
    { "F0Ac", "fan 0 actual rpm" },
    { "F0Mn", "fan 0 min rpm" },
    { "F0Mx", "fan 0 max rpm" },
    { "F0Tg", "fan 0 target rpm" },
    { "F0Md", "fan 0 mode (0 auto / 1 manual)" },
    { "F0md", "fan 0 mode (lowercase variant on some fw)" },
    { "F0Sf", "fan 0 safe rpm" },
    { "F1Ac", "fan 1 actual rpm" },
    { "F1Mn", "fan 1 min rpm" },
    { "F1Mx", "fan 1 max rpm" },
    { "F1Tg", "fan 1 target rpm" },
    { "F1Md", "fan 1 mode" },
    { "F1md", "fan 1 mode (lowercase variant)" },
};

static void summary(void) {
    char model[64] = {0}, cpu[128] = {0};
    size_t len = sizeof model; sysctlbyname("hw.model", model, &len, NULL, 0);
    len = sizeof cpu; sysctlbyname("machdep.cpu.brand_string", cpu, &len, NULL, 0);
    printf("== System ==\n  %s  (%s)\n\n", cpu, model);

    printf("== Battery (IORegistry: AppleSmartBattery) ==\n");
    print_battery();

    uint32_t n = 0;
    KeyName *keys = all_keys(&n);
    printf("\n== SMC ==\n  #KEY reports %u keys, enumerated %u\n", smc_key_count(), n);

    printf("\n== Known control/monitor keys (names from M1–M4 tooling; verify!) ==\n");
    for (size_t i = 0; i < sizeof kKnown / sizeof kKnown[0]; i++) {
        SMCVal v = smc_read(kKnown[i].key);
        print_val(&v, kKnown[i].note);
    }

    const char *families[] = { "CH", "F", "TB", "B", "AC" };
    const char *titles[] = { "CH* (charger control)", "F* (fans)", "TB* (battery temperatures)", "B* (battery)", "AC* (adapter)" };
    for (int f = 0; f < 5; f++) {
        printf("\n== %s ==\n", titles[f]);
        size_t pl = strlen(families[f]);
        int cnt = 0;
        for (uint32_t i = 0; i < n; i++) {
            if (strncmp(keys[i].key, families[f], pl) != 0) continue;
            SMCVal v = smc_read(keys[i].key);
            print_val(&v, NULL);
            cnt++;
        }
        if (!cnt) printf("  (none)\n");
    }

    int tcount = 0;
    for (uint32_t i = 0; i < n; i++) if (keys[i].key[0] == 'T') tcount++;
    printf("\n== T* temperature keys: %d (see `smcprobe dump | grep '^T'`) ==\n", tcount);

    printf("\n== HID temperature sensors ==\n");
    print_hid();
    free(keys);
}

static void dump(void) {
    uint32_t n = 0;
    KeyName *keys = all_keys(&n);
    for (uint32_t i = 0; i < n; i++) {
        SMCVal v = smc_read(keys[i].key);
        char hex[80] = "", dec[64] = "";
        if (v.ok) { fmt_hex(&v, hex, sizeof hex); fmt_decoded(&v, dec, sizeof dec); }
        printf("%-4s %-4s %2u %-64s %s\n", v.key, v.ok ? v.type : "????", v.size, v.ok ? hex : "(read error)", dec);
    }
    free(keys);
}

static void watch(int argc, char **argv) {
    int k = argc;
    SMCVal *prev = calloc(k, sizeof(SMCVal));
    bool first = true;
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        for (int i = 0; i < k; i++) {
            SMCVal v = smc_read(argv[i]);
            if (first || v.ok != prev[i].ok || v.size != prev[i].size || memcmp(v.bytes, prev[i].bytes, v.size) != 0) {
                time_t t = time(NULL); char ts[16];
                strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
                printf("%s", ts);
                print_val(&v, NULL);
                prev[i] = v;
            }
        }
        first = false;
        sleep(1);
    }
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "summary";
    if (!strcmp(cmd, "hid")) { print_hid(); return 0; }
    if (!smc_open()) return 1;
    if (!strcmp(cmd, "summary")) summary();
    else if (!strcmp(cmd, "dump")) dump();
    else if (!strcmp(cmd, "read")) { for (int i = 2; i < argc; i++) { SMCVal v = smc_read(argv[i]); print_val(&v, NULL); } }
    else if (!strcmp(cmd, "watch") && argc > 2) watch(argc - 2, argv + 2);
    else { fprintf(stderr, "usage: smcprobe [summary|dump|read KEY..|watch KEY..|hid]\n"); return 2; }
    IOServiceClose(g_conn);
    return 0;
}
