#include "smc.h"
#include <string.h>

#define KERNEL_INDEX_SMC 2

#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved[1];
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

_Static_assert(sizeof(SMCParam) == 80, "AppleSMC expects an 80-byte parameter block");

static kern_return_t smc_call(io_connect_t conn, SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), out, &outSize);
    if (kr != KERN_SUCCESS) return kr;
    // A non-zero result is the SMC's own error code (0x84 = key not found).
    return out->result == 0 ? KERN_SUCCESS : (kern_return_t)out->result;
}

kern_return_t smc_open(io_connect_t *conn) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    return kr;
}

void smc_close(io_connect_t conn) {
    IOServiceClose(conn);
}

kern_return_t smc_key_info(io_connect_t conn, uint32_t key, SMCKeyInfo *info) {
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(conn, &in, &out);
    if (kr == KERN_SUCCESS) *info = out.keyInfo;
    return kr;
}

kern_return_t smc_read(io_connect_t conn, uint32_t key, SMCKeyInfo *info, uint8_t bytes[32]) {
    kern_return_t kr = smc_key_info(conn, key, info);
    if (kr != KERN_SUCCESS) return kr;
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    kr = smc_call(conn, &in, &out);
    if (kr == KERN_SUCCESS) memcpy(bytes, out.bytes, 32);
    return kr;
}

kern_return_t smc_write(io_connect_t conn, uint32_t key, const uint8_t *bytes, uint32_t size) {
    SMCKeyInfo info;
    kern_return_t kr = smc_key_info(conn, key, &info);
    if (kr != KERN_SUCCESS) return kr;
    if (size != info.dataSize || size > 32) return kIOReturnBadArgument;
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    return smc_call(conn, &in, &out);
}

kern_return_t smc_key_count(io_connect_t conn, uint32_t *count) {
    SMCKeyInfo info;
    uint8_t bytes[32];
    // '#KEY' holds the key count as a big-endian ui32.
    kern_return_t kr = smc_read(conn, ('#' << 24) | ('K' << 16) | ('E' << 8) | 'Y', &info, bytes);
    if (kr != KERN_SUCCESS) return kr;
    *count = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
    return KERN_SUCCESS;
}

kern_return_t smc_key_at_index(io_connect_t conn, uint32_t index, uint32_t *key) {
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    kern_return_t kr = smc_call(conn, &in, &out);
    if (kr == KERN_SUCCESS) *key = out.key;
    return kr;
}
