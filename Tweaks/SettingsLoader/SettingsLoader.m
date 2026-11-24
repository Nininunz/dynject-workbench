// SettingsLoader: tweak settings as native pages in System Settings, the macOS counterpart of iOS's PreferenceLoader.
//
// System Settings (macOS 27) lists its pages from Settings extensions and hosts each one in an ExtensionKit
// _EXHostViewController. SettingsLoader registers one stub extension ("Tweaks", Extension/), puts it into the sidebar
// (System Settings leaves third-party extensions out of it), and when that page is shown it never launches the stub:
// it turns hosting off for it and lays its own SwiftUI page (SettingsLoader.swift) over the host's placeholder.
// Pushing a page and the header's back/forward go through System Settings' own navigation history, the way Apple's
// pages do (see SettingsLoader.swift).
//
// This file has the Objective-C hooks; everything else is in SettingsLoader.swift.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import "DynjectHook.h"

#define SL_TWEAK_ID "local.dynject.settingsloader"
static NSString *const kExtensionID = @"local.dynject.settingsloader.extension";

// SettingsLoader.swift
extern NSViewController *SLMakePageController(void);
extern void SLPageAttached(void);
extern void SLPageDetached(void);
extern void SLSawCoordinator(id coordinator);
extern void SLStart(void);
extern void SLSawHistoryManager(id manager);

static const void *kOursKey = &kOursKey;   // on an _EXHostViewController: it hosts our extension
static const void *kPageKey = &kPageKey;   // on an _EXHostViewController: our page's view controller

static BOOL IsOurConfiguration(id config) {
    if (![config respondsToSelector:@selector(extensionIdentity)]) return NO;
    id identity = ((id (*)(id, SEL))objc_msgSend)(config, @selector(extensionIdentity));
    if (![identity respondsToSelector:@selector(bundleIdentifier)]) return NO;
    NSString *bid = ((id (*)(id, SEL))objc_msgSend)(identity, @selector(bundleIdentifier));
    return [bid isEqualToString:kExtensionID];
}

/// Puts our page's view on top of the host's own subviews (the placeholder), filling it. The host swaps its subviews
/// when it (re)embeds the placeholder, so this runs again after that and after each layout.
static void AttachPageView(NSViewController *host) {
    NSViewController *page = objc_getAssociatedObject(host, kPageKey);
    if (!page) return;
    NSView *view = page.view;
    if (view.superview == host.view && view == host.view.subviews.lastObject) return;
    [view removeFromSuperview];
    view.frame = host.view.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [host.view addSubview:view positioned:NSWindowAbove relativeTo:nil];
}

static void EmbedPage(NSViewController *host) {
    if (![objc_getAssociatedObject(host, kOursKey) boolValue] || objc_getAssociatedObject(host, kPageKey)) return;
    NSViewController *page = SLMakePageController();
    objc_setAssociatedObject(host, kPageKey, page, OBJC_ASSOCIATION_RETAIN);
    [host addChildViewController:page];
    AttachPageView(host);
    SLPageAttached();
}

/// The host is being set to another pane: take our page out. (System Settings keeps one host and reconfigures it
/// for each pane it shows.)
static void RemovePage(NSViewController *host) {
    NSViewController *page = objc_getAssociatedObject(host, kPageKey);
    objc_setAssociatedObject(host, kOursKey, nil, OBJC_ASSOCIATION_RETAIN);
    if (!page) return;
    [page.view removeFromSuperview];
    [page removeFromParentViewController];
    objc_setAssociatedObject(host, kPageKey, nil, OBJC_ASSOCIATION_RETAIN);
    SLPageDetached();
}

// MARK: Finding the navigation history

// SettingsApp.SettingsNavigationHistoryManager (back/forward) is a pure Swift object held in SwiftUI state, out of
// Mirror's reach. There is one per window: find it once by scanning the heap for objects of its class.
static uintptr_t sHistoryClass;
static size_t sHistorySize;
static kern_return_t ReadLocal(task_t task, vm_address_t address, vm_size_t size, void **out) {
    (void)task; (void)size;
    *out = (void *)address;
    return KERN_SUCCESS;
}
static void RecordRanges(task_t task, void *context, unsigned type, vm_range_t *ranges, unsigned count) {
    (void)task; (void)type;
    NSMutableArray *found = (__bridge NSMutableArray *)context;
    const uintptr_t mask = 0x0000000ffffffff8ULL;
    for (unsigned i = 0; i < count; i++) {
        if (ranges[i].size < sHistorySize) continue;
        uintptr_t isa = *(uintptr_t *)ranges[i].address;
        if ((isa & mask) == (sHistoryClass & mask)) [found addObject:@(ranges[i].address)];
    }
}
void SLFindHistoryManagers(void) {
    Class cls = objc_getClass("_TtC11SettingsApp32SettingsNavigationHistoryManager");
    if (!cls) { DHLog(@"no SettingsNavigationHistoryManager class"); return; }
    sHistoryClass = (uintptr_t)cls;
    sHistorySize = class_getInstanceSize(cls);
    vm_address_t *zones = NULL;
    unsigned zoneCount = 0;
    if (malloc_get_all_zones(mach_task_self(), ReadLocal, &zones, &zoneCount) != KERN_SUCCESS) return;
    NSMutableArray *found = [NSMutableArray array];
    for (unsigned z = 0; z < zoneCount; z++) {
        malloc_zone_t *zone = (malloc_zone_t *)zones[z];
        if (!zone || !zone->introspect || !zone->introspect->enumerator) continue;
        zone->introspect->enumerator(mach_task_self(), (__bridge void *)found, MALLOC_PTR_IN_USE_RANGE_TYPE,
                                     (vm_address_t)zone, ReadLocal, RecordRanges);
    }
    for (NSNumber *address in found) SLSawHistoryManager((__bridge id)(void *)address.unsignedLongValue);
}

static DHHook *sSetConfiguration, *sWillAppear, *sDidDisappear, *sEmbedPlaceholder, *sDidLayout, *sBeginHosting;

static void HostSetConfiguration(NSViewController *self, SEL _cmd, id config) {
    BOOL ours = IsOurConfiguration(config);
    RemovePage(self);
    if (ours) {
        objc_setAssociatedObject(self, kOursKey, @YES, OBJC_ASSOCIATION_RETAIN);
        // Never start the stub extension: it has nothing to show.
        @try {
            [config setValue:@NO forKey:@"beginHostingImmediately"];
            [config setValue:@NO forKey:@"retryOnHostingFailure"];
        } @catch (NSException *e) {
            DHLog(@"can't turn hosting off for our page: %@", e.reason);
        }
    }
    DH_CALL_ORIG(sSetConfiguration, void (*)(id, SEL, id), self, _cmd, config);
    if (ours) dispatch_async(dispatch_get_main_queue(), ^{ EmbedPage(self); });
}

static void HostWillAppear(NSViewController *self, SEL _cmd) {
    DH_CALL_ORIG(sWillAppear, void (*)(id, SEL), self, _cmd);
    AttachPageView(self);   // the window shown again with our page in it
}

static void HostDidDisappear(NSViewController *self, SEL _cmd) {
    DH_CALL_ORIG(sDidDisappear, void (*)(id, SEL), self, _cmd);
    if (objc_getAssociatedObject(self, kPageKey)) SLPageDetached();
}

static void HostEmbedPlaceholder(NSViewController *self, SEL _cmd) {
    DH_CALL_ORIG(sEmbedPlaceholder, void (*)(id, SEL), self, _cmd);
    AttachPageView(self);
}

static void HostDidLayout(NSViewController *self, SEL _cmd) {
    DH_CALL_ORIG(sDidLayout, void (*)(id, SEL), self, _cmd);
    AttachPageView(self);
}

// Any page beginning to show: the coordinator leads SettingsLoader to the sidebar's model.
static void CoordinatorBeginHosting(id self, SEL _cmd) {
    DH_CALL_ORIG(sBeginHosting, void (*)(id, SEL), self, _cmd);
    SLSawCoordinator(self);
}

DH_CTOR(SL_TWEAK_ID, "com.apple.systempreferences") {
    DH_REQUIRE_SYSTEM("27.0");   // = minimumSystemVersion in SettingsLoader.workbench.plist
    Class host = DHClass("_EXHostViewController");
    Class coordinator = DHClass("SettingsApp.SystemSettingsExtensionCoordinator");
    SEL embedPlaceholder = NSSelectorFromString(@"embedPlaceholder");
    SEL beginHosting = NSSelectorFromString(@"didBeginHosting");
    if (!host || !coordinator || ![host instancesRespondToSelector:embedPlaceholder]
        || ![coordinator instancesRespondToSelector:beginHosting]) {
        DHLog(@"SettingsLoader inactive: %s", !host ? "no _EXHostViewController"
              : !coordinator ? "no SettingsApp.SystemSettingsExtensionCoordinator"
              : "a hooked method is missing");
        return;
    }
    sSetConfiguration = DHHookMessage(host, @selector(setConfiguration:), (IMP)HostSetConfiguration, NULL);
    sWillAppear = DHHookMessage(host, @selector(viewWillAppear), (IMP)HostWillAppear, NULL);
    sDidDisappear = DHHookMessage(host, @selector(viewDidDisappear), (IMP)HostDidDisappear, NULL);
    sEmbedPlaceholder = DHHookMessage(host, embedPlaceholder, (IMP)HostEmbedPlaceholder, NULL);
    sDidLayout = DHHookMessage(host, @selector(viewDidLayout), (IMP)HostDidLayout, NULL);
    sBeginHosting = DHHookMessage(coordinator, beginHosting, (IMP)CoordinatorBeginHosting, NULL);
    if (!sSetConfiguration || !sWillAppear || !sDidDisappear || !sEmbedPlaceholder || !sDidLayout || !sBeginHosting) {
        DHLog(@"SettingsLoader: some hooks failed (config %d appear %d disappear %d placeholder %d layout %d hosting %d)",
              !!sSetConfiguration, !!sWillAppear, !!sDidDisappear, !!sEmbedPlaceholder, !!sDidLayout, !!sBeginHosting);
    }
    SLStart();
}
