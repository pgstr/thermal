// fantest — M1: minimal, guarded SMC fan WRITE test for Apple Silicon (M5 Pro).
//
// Writes ONLY these keys (hard allowlist): F0md F1md F0Tg F1Tg FEna
// Every rpm is clamped to [FnMn, FnMx]. On normal exit, error, Ctrl-C or SIGTERM
// it restores Apple's automatic control (FnMd = 0, FEna back to its original value).
//
// Build:  clang -O2 -Wall -o fantest fantest.c -framework IOKit -framework CoreFoundation
// Run:    sudo ./fantest run            scripted test (~80 s), log to runs/m1/
//         sudo ./fantest auto           emergency: hand fans back to Apple
//         ./fantest status              read-only status line

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

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

static io_connect_t g_conn;
static FILE *g_log;
static volatile sig_atomic_t g_stop;
static bool g_wrote_fena;
static unsigned char g_fena_orig;
static bool g_restored = true;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(unsigned char)s[0] << 24) | ((uint32_t)(unsigned char)s[1] << 16) |
           ((uint32_t)(unsigned char)s[2] << 8) | (uint32_t)(unsigned char)s[3];
}

static void out(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void out(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    if (g_log) { va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap); fflush(g_log); }
    fflush(stdout);
}

static kern_return_t smc_call(SMCParam *in, SMCParam *o) {
    size_t sz = sizeof(SMCParam);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), o, &sz);
}

static bool keyinfo(const char *key, uint32_t *size, uint32_t *type) {
    SMCParam in = {0}, o = {0};
    in.key = fourcc(key); in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &o) != KERN_SUCCESS || o.result) return false;
    *size = o.keyInfo.dataSize; *type = o.keyInfo.dataType;
    return true;
}

static bool smc_read(const char *key, unsigned char *buf, uint32_t *size) {
    uint32_t sz, ty;
    if (!keyinfo(key, &sz, &ty) || sz > 32) return false;
    SMCParam in = {0}, o = {0};
    in.key = fourcc(key); in.keyInfo.dataSize = sz; in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &o) != KERN_SUCCESS || o.result) return false;
    memcpy(buf, o.bytes, sz); *size = sz;
    return true;
}

static float read_flt(const char *key) {
    unsigned char b[32]; uint32_t n;
    if (!smc_read(key, b, &n) || n != 4) return -1;
    float f; memcpy(&f, b, 4); return f;
}
static int read_u8(const char *key) {
    unsigned char b[32]; uint32_t n;
    if (!smc_read(key, b, &n) || n < 1) return -1;
    return b[0];
}

static const char *kAllowed[] = { "F0md", "F1md", "F0Tg", "F1Tg", "FEna" };

// Returns 0 on success, otherwise IOKit error or SMC result code (shown in hex).
static int smc_write(const char *key, const unsigned char *data, uint32_t len) {
    bool ok = false;
    for (size_t i = 0; i < sizeof kAllowed / sizeof kAllowed[0]; i++) if (!strcmp(key, kAllowed[i])) ok = true;
    if (!ok) { out("REFUSED write to non-allowlisted key %s\n", key); return -1; }
    uint32_t sz, ty;
    if (!keyinfo(key, &sz, &ty)) return -2;
    if (sz != len) { out("REFUSED %s: size %u != %u\n", key, sz, len); return -3; }
    SMCParam in = {0}, o = {0};
    in.key = fourcc(key); in.data8 = SMC_CMD_WRITE_BYTES; in.keyInfo.dataSize = sz;
    memcpy(in.bytes, data, len);
    kern_return_t kr = smc_call(&in, &o);
    if (kr != KERN_SUCCESS) return kr;
    return (unsigned char)o.result;
}

static int write_u8(const char *key, unsigned char v) { return smc_write(key, &v, 1); }

static int write_rpm(int fan, float rpm) {
    char kMn[5], kMx[5], kTg[5];
    snprintf(kMn, 5, "F%dMn", fan); snprintf(kMx, 5, "F%dMx", fan); snprintf(kTg, 5, "F%dTg", fan);
    float mn = read_flt(kMn), mx = read_flt(kMx);
    if (mn <= 0 || mx <= mn) { out("cannot read limits for fan %d\n", fan); return -4; }
    if (rpm < mn) rpm = mn;
    if (rpm > mx) rpm = mx;
    unsigned char b[4]; memcpy(b, &rpm, 4);
    return smc_write(kTg, b, 4);
}

static void status_line(const char *tag) {
    time_t t = time(NULL); char ts[16]; strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
    out("%s %-10s md=%d/%d Tg=%4.0f/%4.0f Ac=%4.0f/%4.0f St=%d/%d FEna=%02x FPSt=%d TB0T=%.1f\n", ts, tag,
        read_u8("F0md"), read_u8("F1md"), read_flt("F0Tg"), read_flt("F1Tg"), read_flt("F0Ac"), read_flt("F1Ac"),
        read_u8("F0St"), read_u8("F1St"), read_u8("FEna") & 0xff, read_u8("FPSt"), read_flt("TB0T"));
}

static void restore_auto(void) {
    if (g_restored) return;
    int r0 = write_u8("F0md", 0), r1 = write_u8("F1md", 0), re = 0;
    if (g_wrote_fena) re = write_u8("FEna", g_fena_orig);
    out("RESTORE auto: F0md=0 -> %d, F1md=0 -> %d%s\n", r0, r1, g_wrote_fena ? (re ? ", FEna restore FAILED" : ", FEna restored") : "");
    g_restored = (r0 == 0 && r1 == 0 && re == 0);
}

static void on_signal(int sig) { (void)sig; g_stop = 1; }

// Sleep `secs`, printing status each second. Returns false if interrupted.
static bool observe(const char *tag, int secs) {
    for (int i = 0; i < secs; i++) {
        if (g_stop) return false;
        status_line(tag);
        sleep(1);
    }
    return !g_stop;
}

static bool running(const char *name) {
    char cmd[128]; snprintf(cmd, sizeof cmd, "/usr/bin/pgrep -xq %s", name);
    return system(cmd) == 0;
}

static bool open_smc(void) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!s) return false;
    kern_return_t kr = IOServiceOpen(s, mach_task_self(), 0, &g_conn);
    IOObjectRelease(s);
    return kr == KERN_SUCCESS;
}

static void report(const char *what, int rc) {
    if (rc == 0) out("  write %-28s ok\n", what);
    else out("  write %-28s FAILED rc=0x%x%s\n", what, (unsigned)rc, rc == (int)kIOReturnNotPrivileged ? " (not privileged: run with sudo)" : "");
}

static float avg_ac(void) { return (read_flt("F0Ac") + read_flt("F1Ac")) / 2; }

static int run_test(void) {
    if (geteuid() != 0) { fprintf(stderr, "run requires root: sudo ./fantest run\n"); return 1; }
    if (running("Fandy")) { fprintf(stderr, "Fandy is running. Quit Fandy first (its helper may stay).\n"); return 1; }
    mkdir("runs", 0755); mkdir("runs/m1", 0755);
    g_log = fopen("runs/m1/log.txt", "w");
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal); signal(SIGHUP, on_signal);
    atexit(restore_auto);

    out("== M1 fan write test ==  FandyFanHelper running: %s\n", running("FandyFanHelper") ? "yes" : "no");
    int fena = read_u8("FEna"); g_fena_orig = (unsigned char)(fena < 0 ? 0 : fena);
    out("limits: F0 %.0f-%.0f  F1 %.0f-%.0f rpm\n", read_flt("F0Mn"), read_flt("F0Mx"), read_flt("F1Mn"), read_flt("F1Mx"));
    if (!observe("baseline", 5)) goto done;

    out("\n-- A: mode only (F0md=F1md=1, no target) --\n");
    g_restored = false;
    report("F0md=1", write_u8("F0md", 1));
    report("F1md=1", write_u8("F1md", 1));
    if (!observe("A", 8)) goto done;

    out("\n-- B: target 3000 rpm (mode 1 + Tg) --\n");
    report("F0Tg=3000", write_rpm(0, 3000));
    report("F1Tg=3000", write_rpm(1, 3000));
    if (!observe("B", 15)) goto done;
    float b = avg_ac();
    bool spun = b > 2500;
    out("RESULT B: average actual rpm %.0f -> %s\n", b, spun ? "mode + target is ENOUGH" : "fans did not reach target");

    if (!spun) {
        out("\n-- C: also FEna=0x07 (value Fandy had) --\n");
        g_wrote_fena = true;
        report("FEna=07", write_u8("FEna", 0x07));
        report("F0Tg=3000", write_rpm(0, 3000));
        report("F1Tg=3000", write_rpm(1, 3000));
        if (!observe("C", 15)) goto done;
        float c = avg_ac();
        out("RESULT C: average actual rpm %.0f -> %s\n", c, c > 2500 ? "FEna IS required" : "still not spinning");
    }

    out("\n-- D: step to 4500 rpm --\n");
    report("F0Tg=4500", write_rpm(0, 4500));
    report("F1Tg=4500", write_rpm(1, 4500));
    if (!observe("D", 12)) goto done;

    out("\n-- E: clamp check, request 1000 rpm (below min) --\n");
    report("F0Tg=1000 (clamped)", write_rpm(0, 1000));
    report("F1Tg=1000 (clamped)", write_rpm(1, 1000));
    if (!observe("E", 6)) goto done;

done:
    if (g_stop) out("\nINTERRUPTED\n");
    out("\n-- F: hand back to Apple --\n");
    restore_auto();
    for (int i = 0; i < 12; i++) { status_line("F/auto"); sleep(1); }
    out("\nDONE. Log: runs/m1/log.txt\n");
    if (g_log) fclose(g_log), g_log = NULL;
    return g_restored ? 0 : 2;
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "status";
    if (!open_smc()) { fprintf(stderr, "cannot open AppleSMC\n"); return 1; }
    if (!strcmp(cmd, "status")) { status_line("status"); return 0; }
    if (!strcmp(cmd, "auto")) { g_restored = false; g_wrote_fena = false; restore_auto(); return g_restored ? 0 : 2; }
    if (!strcmp(cmd, "run")) return run_test();
    fprintf(stderr, "usage: fantest [status|run|auto]\n");
    return 2;
}
