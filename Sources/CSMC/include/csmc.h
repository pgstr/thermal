#ifndef CSMC_H
#define CSMC_H

#include <stdbool.h>
#include <stdint.h>

// ---------- SMC (read-only) ----------

typedef struct {
    char key[5];       // NUL-terminated four-char key
    char type[5];      // NUL-terminated four-char type, e.g. "flt ", "ui8 "
    uint32_t size;     // number of valid bytes
    uint8_t bytes[32];
} csmc_value;

// Opens a connection to AppleSMC. Returns 0 on failure.
uint32_t csmc_open(void);
void csmc_close(uint32_t conn);

// Returns 0 on success; otherwise an IOKit error or the SMC result code (0x84 = key not found).
int csmc_read(uint32_t conn, const char *key, csmc_value *out);

// Number of keys (#KEY) and key name at index (into out[5]). Return 0 on success.
int csmc_key_count(uint32_t conn, uint32_t *count);
int csmc_key_at(uint32_t conn, uint32_t index, char out[5]);

// ---------- HID temperature sensors (private IOKit API) ----------

typedef struct {
    int index;           // service index, for csmc_hid_set_enabled
    char name[64];       // "Product" property, e.g. "PMU tdie3"
    uint64_t location;   // "LocationID" property (0 if absent) — distinguishes same-named sensors
    double celsius;
} csmc_hid_temp;

// Opaque handle; create once and reuse (creating per sample is expensive).
typedef struct csmc_hid csmc_hid;
csmc_hid *csmc_hid_create(void);
void csmc_hid_destroy(csmc_hid *h);

// Fills up to `max` entries for enabled services; returns the number written.
// Values are raw (no plausibility filter). Names/locations are cached at create time.
int csmc_hid_read(csmc_hid *h, csmc_hid_temp *out, int max);
int csmc_hid_count(csmc_hid *h);
// Stop polling a service (e.g. one that only ever reports implausible values).
void csmc_hid_set_enabled(csmc_hid *h, int index, bool enabled);

#endif
