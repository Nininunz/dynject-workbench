// Tweak A: hooks -[HHTarget value] (first), getppid, and the function hh_compute (first).
#import <dlfcn.h>
#import "DynjectHook.h"
static DHHook *sValue;
static DHImportHook *sPPID;
static DHFunctionHook *sCompute;
static int ACompute(int x) { return DH_CALL_FUNCTION_ORIG(sCompute, int (*)(int), x) + 1000; }
static int AValue(id self, SEL _cmd) { return DH_CALL_ORIG(sValue, int (*)(id, SEL), self, _cmd) + 10; }
static pid_t APPID(void) { return DH_CALL_IMPORT_ORIG(sPPID, pid_t (*)(void)) ? 424242 : 0; }
DH_CTOR("local.hooks.a") {
    sValue = DHHookMessage(DHClass("HHTarget"), @selector(value), (IMP)AValue, NULL);
    sPPID = DHHookImport("getppid", NULL, (void *)APPID, NULL);
    sCompute = DHHookFunction(dlsym(RTLD_DEFAULT, "hh_compute"), (void *)ACompute, NULL);
}
