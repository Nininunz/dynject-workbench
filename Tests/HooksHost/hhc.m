// Tweak C: no DynjectHook; swaps -[HHTarget third] with method_setImplementation. Only `dw hooks --scan` sees it.
#import <objc/runtime.h>
static int CThird(id self, SEL _cmd) { (void)self; (void)_cmd; return 33; }
__attribute__((constructor)) static void C(void) {
    Method m = class_getInstanceMethod(objc_getClass("HHTarget"), sel_registerName("third"));
    if (m) method_setImplementation(m, (IMP)CThird);
}
