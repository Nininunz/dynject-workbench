// The respring end-to-end test's "tweak": does nothing but note, in $RESPRING_E2E_LOG, which process loaded it.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

__attribute__((constructor)) static void respring_e2e_loaded(void) {
    const char *path = getenv("RESPRING_E2E_LOG");
    if (!path) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char line[64];
    int n = snprintf(line, sizeof line, "loaded pid %d\n", (int)getpid());
    if (n > 0) write(fd, line, (size_t)n);
    close(fd);
}
