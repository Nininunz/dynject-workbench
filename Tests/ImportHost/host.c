// Calls the hooked functions and checks what comes back. Exit status: the number of failed checks.
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

int dhih_value1(int x);
int dhih_value3(int x);
int dhih_call_from_dylib(int x);

static int failures, checks;
static void check(const char *what, long got, long want) {
    printf("%s %s: %ld%s\n", got == want ? "[ok]  " : "[FAIL]", what, got, got == want ? "" : " (wrong)");
    checks++;
    if (got != want) failures++;
}

int main(int argc, char **argv) {
    void (*setEnabled)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "dhih_probe_set_enabled");
    unsigned long (*sites)(int) = (unsigned long (*)(int))dlsym(RTLD_DEFAULT, "dhih_probe_sites");
    if (!setEnabled || !sites) { printf("[FAIL] the probe isn't loaded\n"); return 1; }
    check("main executable's import", dhih_value1(1), 101);
    check("a dylib's import, library filter", dhih_call_from_dylib(2), 202);
    check("libSystem import (getppid)", getppid(), 424242);
    check("grouped hook", dhih_value3(3), 303);
    setEnabled(0);
    check("grouped hook, group off", dhih_value3(3), 3);
    check("its imports while off", (long)sites(2), 0);
    setEnabled(1);
    check("grouped hook, group on again", dhih_value3(3), 303);
    void *late = argc > 1 ? dlopen(argv[1], RTLD_NOW) : NULL;   // libDHIHLate.dylib
    int (*callLate)(int) = late ? (int (*)(int))dlsym(late, "dhih_call_late") : NULL;
    check("image loaded later", callLate ? callLate(4) : -1, 404);
    printf("%d checks, %s\n", checks, failures ? "FAILED" : "all passed");
    return failures;
}
