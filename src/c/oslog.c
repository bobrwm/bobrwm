// Clang expands os_log_with_type and preserves the metadata logd requires.
// Zig formats each record first, so the bridge receives one public string.
#include <os/log.h>

void bw_os_log(os_log_t log, os_log_type_t type, const char *message) {
    os_log_with_type(log, type, "%{public}s", message);
}
