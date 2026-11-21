// The tweak under test: import hooks installed in DH_CTOR, injected with DYLD_INSERT_LIBRARIES.
#import "DynjectHook.h"
#import <unistd.h>

typedef int (*IntFn)(int);
static DHImportHook *sOne, *sTwo, *sThree, *sFour, *sPPID;
static DHGroup *sGroup;

static int One(int x) { return DH_CALL_IMPORT_ORIG(sOne, IntFn, x) + 100; }
static int Two(int x) { return DH_CALL_IMPORT_ORIG(sTwo, IntFn, x) + 200; }
static int Three(int x) { return DH_CALL_IMPORT_ORIG(sThree, IntFn, x) + 300; }
static int Four(int x) { return DH_CALL_IMPORT_ORIG(sFour, IntFn, x) + 400; }
static pid_t PPID(void) { return DH_CALL_IMPORT_ORIG(sPPID, pid_t (*)(void)) > 0 ? 424242 : -1; }

// The host's handle on the probe (the only exported symbols).
__attribute__((visibility("default"))) void dhih_probe_set_enabled(int enabled) { DHGroupSetEnabled(sGroup, enabled ? YES : NO); }
__attribute__((visibility("default"))) unsigned long dhih_probe_sites(int which) {
    DHImportHook *hooks[] = {sOne, sTwo, sThree, sFour, sPPID};
    return which >= 0 && which < 5 ? DHImportHookSiteCount(hooks[which]) : 0;
}

DH_CTOR("local.dynject.importhost") {
    sGroup = DHGroupCreate("importhost");
    sOne = DHHookImport("dhih_value1", NULL, (void *)One, NULL);
    sTwo = DHHookImport("dhih_value2", "libDHIHProvider.dylib", (void *)Two, NULL);
    sThree = DHHookImport("dhih_value3", NULL, (void *)Three, sGroup);
    sFour = DHHookImport("dhih_value4", NULL, (void *)Four, NULL);
    sPPID = DHHookImport("getppid", "libSystem.B.dylib", (void *)PPID, NULL);
}
