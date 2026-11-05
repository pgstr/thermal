#ifndef CFANWRITE_H
#define CFANWRITE_H

#include <stdint.h>

// SMC fan writes for the privileged helper ONLY. The app never links this module.
//
// Hard allowlist enforced here: F<digit>md (mode, ui8) and F<digit>Tg (target, flt).
// Anything else returns -1 without touching the SMC. Requires root.

uint32_t cfw_open(void);
void cfw_close(uint32_t conn);

// Returns 0 on success; -1 not allowlisted; -2 key info failed; -3 size mismatch;
// otherwise IOKit error or SMC result code.
int cfw_write_mode(uint32_t conn, int fan, uint8_t manual);
int cfw_write_target(uint32_t conn, int fan, float rpm);

// Reads (for clamping and status). Return 0 on success.
int cfw_read_float(uint32_t conn, const char *key, float *out);
int cfw_read_u8(uint32_t conn, const char *key, uint8_t *out);

#endif
