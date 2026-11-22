// Inspector: menus. What a menu item does (its action, where that goes, which method runs), and picking one: while
// picking, choosing any menu item (from the menu bar, a context menu, or by its key equivalent) opens it in the panel
// instead of sending its action.
//
// Picking hooks -[NSApplication sendAction:to:from:], through which every menu item sends its action, in a DynjectHook
// group that is on only while picking: the rest of the time Inspector hooks nothing for it.
#import "DYIInternal.h"
#import "DynjectHook.h"

NSString *DYIKeyEquivalentString(NSMenuItem *item) {
    NSString *key = item.keyEquivalent;
    if (!key.length) return @"";
    NSMutableString *s = [NSMutableString string];
    NSEventModifierFlags m = item.keyEquivalentModifierMask;
    if (m & NSEventModifierFlagFunction) [s appendString:@"fn "];
    if (m & NSEventModifierFlagControl) [s appendString:@"⌃"];
    if (m & NSEventModifierFlagOption) [s appendString:@"⌥"];
    // A capital letter means Shift, whether or not the mask says so.
    unichar c = [key characterAtIndex:0];
    BOOL upper = [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:c];
    if ((m & NSEventModifierFlagShift) || upper) [s appendString:@"⇧"];
    if (m & NSEventModifierFlagCommand) [s appendString:@"⌘"];
    NSString *name;
    switch (c) {
        case '\r': case 3: name = @"↩"; break;
        case '\t': name = @"⇥"; break;
        case 0x1b: name = @"⎋"; break;
        case 0x08: case 0x7f: name = @"⌫"; break;
        case ' ': name = @"Space"; break;
        case NSUpArrowFunctionKey: name = @"↑"; break;
        case NSDownArrowFunctionKey: name = @"↓"; break;
        case NSLeftArrowFunctionKey: name = @"←"; break;
        case NSRightArrowFunctionKey: name = @"→"; break;
        case NSDeleteFunctionKey: name = @"⌦"; break;
        case NSHomeFunctionKey: name = @"↖"; break;
        case NSEndFunctionKey: name = @"↘"; break;
        case NSPageUpFunctionKey: name = @"⇞"; break;
        case NSPageDownFunctionKey: name = @"⇟"; break;
        default:
            if (c >= NSF1FunctionKey && c <= NSF35FunctionKey) name = [NSString stringWithFormat:@"F%d", c - NSF1FunctionKey + 1];
            else name = key.uppercaseString;
    }
    [s appendString:name];
    return s;
}

id DYIMenuItemReceiver(NSMenuItem *item) {
    if (!item.action) return nil;
    if (item.target) return item.target;
    // Where AppKit would send it: the responder chain of the key window, then the main window, then the app and its
    // delegate (targetForAction:to:from: only asks respondsToSelector: along the way).
    return [NSApp targetForAction:item.action to:nil from:item];
}

Class DYIClassImplementing(id receiver, SEL sel) {
    if (!receiver || !sel) return Nil;
    for (Class c = object_getClass(receiver); c; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *list = class_copyMethodList(c, &n);
        BOOL found = NO;
        for (unsigned int i = 0; i < n && !found; i++) found = method_getName(list[i]) == sel;
        free(list);
        if (found) return c;
    }
    return Nil;
}

NSString *DYIMenuItemSummary(NSMenuItem *item) {
    if (item.isSeparatorItem) return @"separator";
    NSMutableArray *parts = [NSMutableArray array];
    NSString *key = DYIKeyEquivalentString(item);
    if (key.length) [parts addObject:key];
    if (item.submenu) [parts addObject:[NSString stringWithFormat:@"submenu (%ld items)", (long)item.submenu.numberOfItems]];
    if (item.action) [parts addObject:NSStringFromSelector(item.action)];
    if (item.view) [parts addObject:[NSString stringWithFormat:@"view %s", object_getClassName(item.view)]];
    if (!item.isEnabled) [parts addObject:@"disabled"];
    if (item.isHidden) [parts addObject:@"hidden"];
    return parts.count ? [parts componentsJoinedByString:@" · "] : @"(no action)";
}

NSString *DYIMenuItemTitle(NSMenuItem *item) {
    if (item.isSeparatorItem) return @"—";
    NSString *t = item.title.length ? item.title : item.attributedTitle.string;
    return t.length ? [NSString stringWithFormat:@"\"%@\"", t] : @"(untitled)";
}

#pragma mark Picking

static DHGroup *sPickGroup;
static DHHook *sSendAction;
static BOOL sArmed;
static void (^sPicked)(NSMenuItem *item);
static id sEscMonitor;

static BOOL DYIPickSendAction(NSApplication *self, SEL _cmd, SEL action, id to, id from) {
    if (sArmed && [from isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *item = from;
        void (^picked)(NSMenuItem *) = sPicked;
        DYIMenuPickSetArmed(NO, nil);
        DYILog(@"picked menu item %@ (%@)", DYIMenuItemTitle(item), action ? NSStringFromSelector(action) : @"no action");
        if (picked) dispatch_async(dispatch_get_main_queue(), ^{ picked(item); });   // after the menu has closed
        return YES;   // handled: the action isn't sent
    }
    return DH_CALL_ORIG(sSendAction, BOOL (*)(id, SEL, SEL, id, id), self, _cmd, action, to, from);
}

BOOL DYIMenuPickArmed(void) { return sArmed; }

void DYIMenuPickSetArmed(BOOL armed, void (^picked)(NSMenuItem *item)) {
    if (armed) {
        if (!sPickGroup) {
            sPickGroup = DHGroupCreate("menu pick");
            DHGroupSetEnabled(sPickGroup, NO);
            // The app's own class: it may be an NSApplication subclass with its own sendAction:to:from:.
            Class app = NSApp ? object_getClass(NSApp) : [NSApplication class];
            sSendAction = DHHookMessage(app, @selector(sendAction:to:from:), (IMP)DYIPickSendAction, sPickGroup);
            if (!sSendAction) { DYILog(@"menu pick: couldn't hook -[NSApplication sendAction:to:from:]"); return; }
        }
        sPicked = [picked copy];
        sArmed = YES;
        DHGroupSetEnabled(sPickGroup, YES);
        if (!sEscMonitor) {
            sEscMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
                if (sArmed && e.keyCode == 53) {   // esc
                    DYIMenuPickSetArmed(NO, nil);
                    [[DYIPanelController shared] menuPickCancelled];
                    return nil;
                }
                return e;
            }];
        }
    } else {
        sArmed = NO;
        sPicked = nil;
        if (sPickGroup) DHGroupSetEnabled(sPickGroup, NO);
        if (sEscMonitor) { [NSEvent removeMonitor:sEscMonitor]; sEscMonitor = nil; }
    }
}
