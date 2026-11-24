// Tweak B: hooks -[HHTarget value] on top of A, -[HHTarget other] in a group it switches off, and hh_compute on top
// of A's inline hook.
#import <dlfcn.h>
#import "DynjectHook.h"
static DHHook *sValue, *sOther;
static DHFunctionHook *sCompute;
static int BCompute(int x) { return DH_CALL_FUNCTION_ORIG(sCompute, int (*)(int), x) + 20000; }
static int BValue(id self, SEL _cmd) { return DH_CALL_ORIG(sValue, int (*)(id, SEL), self, _cmd) + 100; }
static int BOther(id self, SEL _cmd) { return DH_CALL_ORIG(sOther, int (*)(id, SEL), self, _cmd) + 100; }
DH_CTOR("local.hooks.b") {
    sValue = DHHookMessage(DHClass("HHTarget"), @selector(value), (IMP)BValue, NULL);
    DHGroup *g = DHGroupCreate("b-off");
    sOther = DHHookMessage(DHClass("HHTarget"), @selector(other), (IMP)BOther, g);
    DHGroupSetEnabled(g, NO);
    sCompute = DHHookFunction(dlsym(RTLD_DEFAULT, "hh_compute"), (void *)BCompute, NULL);
}
