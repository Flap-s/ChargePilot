// Minimal access to the AppleSMC user client. The structure layout follows the
// interface the kernel driver expects (80 bytes), so it is declared in C to get
// C padding rules rather than Swift's.
#ifndef CHARGEPILOT_SMC_H
#define CHARGEPILOT_SMC_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

/// Opens a connection to AppleSMC. Returns KERN_SUCCESS on success.
kern_return_t smc_open(io_connect_t *conn);
void smc_close(io_connect_t conn);

/// Reads the type and size of `key` (four-character code packed big-endian).
kern_return_t smc_key_info(io_connect_t conn, uint32_t key, SMCKeyInfo *info);

/// Reads up to 32 bytes of `key` into `bytes`; `info` receives its type and size.
/// Returns KERN_SUCCESS, or an error / SMC result code (>0) on failure.
kern_return_t smc_read(io_connect_t conn, uint32_t key, SMCKeyInfo *info, uint8_t bytes[32]);

/// Writes `size` bytes to `key`. Requires root.
kern_return_t smc_write(io_connect_t conn, uint32_t key, const uint8_t *bytes, uint32_t size);

/// Number of keys the SMC exposes, and the key at a given index.
kern_return_t smc_key_count(io_connect_t conn, uint32_t *count);
kern_return_t smc_key_at_index(io_connect_t conn, uint32_t index, uint32_t *key);

#endif
