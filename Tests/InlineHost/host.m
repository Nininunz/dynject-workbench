// Test host for DHHookFunction (inline hooks), run by run.sh. DynjectHook.m is compiled in; the functions it hooks
// are in fns.s, plus cbrt from the dyld shared cache.
#import <Foundation/Foundation.h>
#import <math.h>
#import <pthread.h>
#import <stdatomic.h>
#import "DynjectHook.h"

int g_value = 7;
extern int f_adrp(void), f_adr(void), f_bl(void), f_b3(void), f_short(void), f_loop(int);
extern int f_bcond(int), f_cbz(int), f_tbz(int);
extern uint64_t f_ldrx(void);
extern uint32_t f_ldrw(void);
extern int64_t f_ldrsw(void);
extern double f_ldrd(void);

static int sChecks, sFailures;
static void Check(BOOL ok, NSString *what) {
    sChecks++;
    if (!ok) sFailures++;
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
}

// One hook per function: the replacement calls the original and adds a marker.
#define HOOK0(name, type, marker)                                                                          \
    static DHFunctionHook *h_##name;                                                                       \
    static type r_##name(void) { return DH_CALL_FUNCTION_ORIG(h_##name, type (*)(void)) + (marker); }
#define HOOK1(name, marker)                                                                                \
    static DHFunctionHook *h_##name;                                                                       \
    static int r_##name(int x) { return DH_CALL_FUNCTION_ORIG(h_##name, int (*)(int), x) + (marker); }

HOOK0(f_adrp, int, 1000)
HOOK0(f_adr, int, 1000)
HOOK0(f_bl, int, 1000)
HOOK0(f_b3, int, 1000)
HOOK0(f_ldrx, uint64_t, 1)
HOOK0(f_ldrw, uint32_t, 1)
HOOK0(f_ldrsw, int64_t, -1)
HOOK0(f_ldrd, double, 1000)
HOOK1(f_bcond, 1000)
HOOK1(f_cbz, 1000)
HOOK1(f_tbz, 1000)

static DHFunctionHook *h_bcond2;
static int r_bcond2(int x) { return DH_CALL_FUNCTION_ORIG(h_bcond2, int (*)(int), x) + 10000; }
static DHFunctionHook *h_cbrt;
static double r_cbrt(double x) { return DH_CALL_FUNCTION_ORIG(h_cbrt, double (*)(double), x) * 2; }
static int r_unused(int x) { return x; }
static DHFunctionHook *h_strlen;
static atomic_long sStrlenCalls;
static size_t r_strlen(const char *str) {
    atomic_fetch_add(&sStrlenCalls, 1);
    return DH_CALL_FUNCTION_ORIG(h_strlen, size_t (*)(const char *), str);
}

static volatile int sStop;
static atomic_long sOdd;
static void *Hammer(void *arg) {
    (void)arg;
    while (!sStop) {
        int r = f_tbz(0);
        if (r != 2 && r != 1002) atomic_fetch_add(&sOdd, 1);
    }
    return NULL;
}

int main(void) {
    @autoreleasepool {
        printf("moved instructions\n");
#define T0(name, type, fmt, marker)                                                                         \
        {                                                                                                  \
            type before = name();                                                                          \
            h_##name = DHHookFunction((void *)name, (void *)r_##name, NULL);                                \
            type after = name(), orig = DH_CALL_FUNCTION_ORIG(h_##name, type (*)(void));                    \
            Check(h_##name && after == (type)(before + (marker)) && orig == before,                          \
                  [NSString stringWithFormat:@#name ": " fmt " → " fmt ", original " fmt, before, after, orig]); \
        }
        T0(f_adrp, int, "%d", 1000)
        T0(f_adr, int, "%d", 1000)
        T0(f_ldrx, uint64_t, "0x%llx", 1)
        T0(f_ldrw, uint32_t, "0x%x", 1)
        T0(f_ldrsw, int64_t, "%lld", -1)
        T0(f_ldrd, double, "%g", 1000)
        T0(f_bl, int, "%d", 1000)
        T0(f_b3, int, "%d", 1000)
#define T1(name, a, b)                                                                                     \
        {                                                                                                  \
            int ba = name(a), bb = name(b);                                                                \
            h_##name = DHHookFunction((void *)name, (void *)r_##name, NULL);                                \
            int aa = name(a), ab = name(b);                                                                \
            Check(h_##name && aa == ba + 1000 && ab == bb + 1000 && ba != bb,                               \
                  [NSString stringWithFormat:@#name ": both ways (%d, %d) → (%d, %d)", ba, bb, aa, ab]);      \
        }
        T1(f_bcond, 3, 9)
        T1(f_cbz, 0, 1)

        printf("refused\n");
        Check(DHHookFunction((void *)f_short, (void *)r_unused, NULL) == NULL && f_short() == 1,
              @"a function shorter than 16 bytes is refused and left alone");
        Check(DHHookFunction((void *)f_loop, (void *)r_unused, NULL) == NULL && f_loop(4) == 4,
              @"a function branching into its first 16 bytes is refused and left alone");
        Check(DHHookFunction(NULL, (void *)r_unused, NULL) == NULL && DHHookFunction((void *)f_short, NULL, NULL) == NULL,
              @"NULL function or replacement: NULL");

        printf("chaining\n");
        h_bcond2 = DHHookFunction((void *)f_bcond, (void *)r_bcond2, NULL);
        int chained = f_bcond(3), below = DH_CALL_FUNCTION_ORIG(h_bcond2, int (*)(int), 3);
        Check(h_bcond2 && chained == 11200 && below == 1200,
              [NSString stringWithFormat:@"a second hook goes on top: %d, its original %d", chained, below]);

        printf("groups\n");
        DHGroup *g = DHGroupCreate("inline");
        h_f_tbz = DHHookFunction((void *)f_tbz, (void *)r_f_tbz, g);
        int on = f_tbz(0);
        DHGroupSetEnabled(g, NO);
        int off = f_tbz(0);
        BOOL inactive = !DHFunctionHookIsActive(h_f_tbz);
        DHGroupSetEnabled(g, YES);
        int again = f_tbz(0);
        Check(on == 1002 && off == 2 && inactive && again == 1002 && DHFunctionHookIsActive(h_f_tbz),
              [NSString stringWithFormat:@"group: on %d, off %d (inactive %d), on again %d", on, off, inactive, again]);

        printf("threads\n");
        pthread_t threads[4];
        for (int i = 0; i < 4; i++) pthread_create(&threads[i], NULL, Hammer, NULL);
        for (int i = 0; i < 2000; i++) DHGroupSetEnabled(g, i % 2);
        DHGroupSetEnabled(g, YES);
        sStop = 1;
        for (int i = 0; i < 4; i++) pthread_join(threads[i], NULL);
        Check(atomic_load(&sOdd) == 0, @"4 threads calling while the group flips 2000 times: only hooked or original results");

        printf("shared cache\n");
        double (*volatile cb)(double) = cbrt;
        double before = cb(27);
        h_cbrt = DHHookFunction((void *)cb, (void *)r_cbrt, NULL);
        double after = cb(27);
        Check(h_cbrt && before == 3 && after == 6, [NSString stringWithFormat:@"cbrt (dyld shared cache): %g → %g", before, after]);

        // A function DynjectHook itself uses (its logging formats strings): nothing in DHHookFunction may call it
        // between writing the jump and returning the handle, or the replacement would call through a NULL handle.
        size_t (*volatile sl)(const char *) = strlen;
        h_strlen = DHHookFunction((void *)sl, (void *)r_strlen, NULL);
        size_t len = sl("hello");
        NSString *formatted = [NSString stringWithFormat:@"%s", "formatting calls strlen"];
        Check(h_strlen && len == 5 && formatted.length == 23 && atomic_load(&sStrlenCalls) >= 1,
              [NSString stringWithFormat:@"strlen, which DynjectHook's own logging uses: hooked, %ld calls so far",
                                         atomic_load(&sStrlenCalls)]);

        printf("%d checks, %d failed\n", sChecks, sFailures);
        return sFailures ? 1 : 0;
    }
}
