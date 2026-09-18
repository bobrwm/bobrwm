// `os_log_with_type` is a compiler macro, not a function: clang encodes the
// format arguments into a private buffer that `_os_log_impl` consumes, so
// there is no symbol for Zig to call and no stable ABI to hand-roll. Zig
// formats the line; this passes it through as one public string.
#include <os/log.h>

void bw_os_log(os_log_t log, os_log_type_t type, const char *message) {
    os_log_with_type(log, type, "%{public}s", message);
}
