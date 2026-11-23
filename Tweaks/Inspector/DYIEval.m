// `dw eval <app> <path>`: reads a value in a running app. Inspector.m receives the request (DYICommandEval); this
// walks the path and formats the value.
//
// Reads only. The path is walked here, step by step, instead of with valueForKeyPath:, because KVC calls any method
// whose name matches a key (`removeFromSuperview`, `close`…). A step is one of:
//   NSApp | app | <ClassName>                  the root (only first)
//   <property>                                 a declared @property (a class property on a class), read with its getter
//   [<n>]  or  .<n>                            an element of an array or ordered set
//   ["<key>"]  or  .<key> on a dictionary      a dictionary value
//   @count  @keys  @class                      count, a dictionary's keys, the class name
// A property step on an array or set that the collection itself doesn't declare is applied to each element.
#import "DYIInternal.h"

typedef NS_ENUM(NSInteger, DYIStepKind) { DYIStepName, DYIStepIndex, DYIStepKey };

@interface DYIStep : NSObject
@property DYIStepKind kind;
@property (copy) NSString *text;
@property NSInteger index;
@end
@implementation DYIStep
@end

static NSArray<DYIStep *> *DYIParse(NSString *path, NSString **error) {
    NSMutableArray<DYIStep *> *steps = [NSMutableArray array];
    NSUInteger i = 0, n = path.length;
    NSMutableString *name = [NSMutableString string];
    void (^flush)(void) = ^{
        if (!name.length) return;
        DYIStep *s = [DYIStep new];
        NSScanner *scan = [NSScanner scannerWithString:name];
        NSInteger number;
        if (steps.count && [scan scanInteger:&number] && scan.isAtEnd && number >= 0) {
            s.kind = DYIStepIndex;
            s.index = number;
        } else {
            s.kind = DYIStepName;
        }
        s.text = [name copy];
        [steps addObject:s];
        [name setString:@""];
    };
    while (i < n) {
        unichar c = [path characterAtIndex:i];
        if (c == '.') { flush(); i++; continue; }
        if (c == '[') {
            flush();
            NSRange close = [path rangeOfString:@"]" options:0 range:NSMakeRange(i, n - i)];
            if (close.location == NSNotFound) { *error = @"a [ without ]"; return nil; }
            NSString *inner = [[path substringWithRange:NSMakeRange(i + 1, close.location - i - 1)]
                               stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            DYIStep *s = [DYIStep new];
            if (inner.length >= 2 && ([inner hasPrefix:@"\""] && [inner hasSuffix:@"\""])) {
                s.kind = DYIStepKey;
                s.text = [inner substringWithRange:NSMakeRange(1, inner.length - 2)];
            } else {
                NSScanner *scan = [NSScanner scannerWithString:inner];
                NSInteger number;
                if (![scan scanInteger:&number] || !scan.isAtEnd || number < 0) {
                    *error = [NSString stringWithFormat:@"[%@]: an index (a number) or a \"key\" in quotes", inner];
                    return nil;
                }
                s.kind = DYIStepIndex;
                s.index = number;
                s.text = inner;
            }
            if (!steps.count) { *error = @"start with NSApp or a class name"; return nil; }
            [steps addObject:s];
            i = close.location + 1;
            continue;
        }
        [name appendFormat:@"%C", c];
        i++;
    }
    flush();
    if (!steps.count) { *error = @"an empty path"; return nil; }
    return steps;
}

/// The declared property `name` of `object` (an instance, or a class for class properties), searched up the chain.
static objc_property_t DYIFindProperty(id object, NSString *name) {
    Class cls = object_getClass(object);   // a class object's class is its metaclass: class properties
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        objc_property_t p = class_getProperty(c, name.UTF8String);
        if (p) return p;
    }
    return NULL;
}

static SEL DYIGetter(objc_property_t p) {
    char *custom = property_copyAttributeValue(p, "G");
    SEL sel = sel_registerName(custom ?: property_getName(p));
    free(custom);
    return sel;
}

/// The getter's result, boxed: objects as they are, numbers as NSNumber, structs as NSValue.
static id DYICallGetter(id object, SEL getter, NSString **error) {
    NSMethodSignature *sig = [object methodSignatureForSelector:getter];
    if (!sig || sig.numberOfArguments != 2) {
        *error = [NSString stringWithFormat:@"%@ doesn't answer %@", DYIDisplayClassName(object), NSStringFromSelector(getter)];
        return nil;
    }
    const char *type = sig.methodReturnType;
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' || *type == 'R' || *type == 'V') type++;
    if (*type == 'v') { *error = [NSString stringWithFormat:@"%@ returns nothing", NSStringFromSelector(getter)]; return nil; }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = getter;
    inv.target = object;
    [inv invoke];
    if (*type == '@' || *type == '#') {
        __unsafe_unretained id value = nil;
        [inv getReturnValue:&value];
        return value;
    }
    NSUInteger size = sig.methodReturnLength;
    void *buffer = calloc(1, MAX(size, (NSUInteger)16));
    [inv getReturnValue:buffer];
    id boxed;
    switch (*type) {
        case 'c': boxed = @(*(signed char *)buffer); break;
        case 'B': boxed = @(*(BOOL *)buffer); break;
        case 'C': boxed = @(*(unsigned char *)buffer); break;
        case 's': boxed = @(*(short *)buffer); break;
        case 'S': boxed = @(*(unsigned short *)buffer); break;
        case 'i': boxed = @(*(int *)buffer); break;
        case 'I': boxed = @(*(unsigned int *)buffer); break;
        case 'l': boxed = @(*(long *)buffer); break;
        case 'L': boxed = @(*(unsigned long *)buffer); break;
        case 'q': boxed = @(*(long long *)buffer); break;
        case 'Q': boxed = @(*(unsigned long long *)buffer); break;
        case 'f': boxed = @(*(float *)buffer); break;
        case 'd': boxed = @(*(double *)buffer); break;
        case ':': boxed = NSStringFromSelector(*(SEL *)buffer); break;
        case '*': boxed = *(char **)buffer ? @(*(char **)buffer) : nil; break;
        case '^': boxed = [NSString stringWithFormat:@"pointer %p", *(void **)buffer]; break;
        default: boxed = [NSValue valueWithBytes:buffer objCType:type]; break;
    }
    free(buffer);
    return boxed;
}

static BOOL DYIIsCollection(id v) {
    return [v isKindOfClass:NSArray.class] || [v isKindOfClass:NSSet.class] || [v isKindOfClass:NSOrderedSet.class];
}

static NSArray *DYIElements(id v) {
    if ([v isKindOfClass:NSArray.class]) return v;
    if ([v isKindOfClass:NSOrderedSet.class]) return [v array];
    if ([v isKindOfClass:NSSet.class]) return [v allObjects];
    return nil;
}

static id DYIStepInto(id object, DYIStep *step, NSString **error);

static id DYIProperty(id object, NSString *name, NSString **error) {
    objc_property_t p = DYIFindProperty(object, name);
    if (!p) {
        BOOL isClass = object_isClass(object);
        *error = [NSString stringWithFormat:@"%@%@ has no %@property %@", isClass ? @"class " : @"",
                  isClass ? NSStringFromClass(object) : DYIDisplayClassName(object), isClass ? @"class " : @"", name];
        return nil;
    }
    return DYICallGetter(object, DYIGetter(p), error);
}

static id DYIStepInto(id object, DYIStep *step, NSString **error) {
    if (!object || object == (id)NSNull.null) { *error = [NSString stringWithFormat:@"nil before %@", step.text]; return nil; }
    switch (step.kind) {
        case DYIStepIndex: {
            NSArray *items = [object isKindOfClass:NSSet.class] ? nil : DYIElements(object);
            if (!items) {
                *error = [NSString stringWithFormat:@"[%ld]: %@ isn't an array", (long)step.index, DYIDisplayClassName(object)];
                return nil;
            }
            if ((NSUInteger)step.index >= items.count) {
                *error = [NSString stringWithFormat:@"[%ld]: only %lu items", (long)step.index, (unsigned long)items.count];
                return nil;
            }
            return items[(NSUInteger)step.index];
        }
        case DYIStepKey:
            if (![object isKindOfClass:NSDictionary.class]) {
                *error = [NSString stringWithFormat:@"[\"%@\"]: %@ isn't a dictionary", step.text, DYIDisplayClassName(object)];
                return nil;
            }
            return [object objectForKey:step.text] ?: NSNull.null;
        case DYIStepName:
            break;
    }
    NSString *name = step.text;
    if ([name isEqualToString:@"@class"]) return object_isClass(object) ? NSStringFromClass(object) : DYIDisplayClassName(object);
    if ([name isEqualToString:@"@count"]) {
        if ([object isKindOfClass:NSDictionary.class] || DYIIsCollection(object)) return @([object count]);
        if ([object isKindOfClass:NSString.class]) return @([object length]);
        *error = [NSString stringWithFormat:@"@count: %@ isn't a collection", DYIDisplayClassName(object)];
        return nil;
    }
    if ([name isEqualToString:@"@keys"]) {
        if (![object isKindOfClass:NSDictionary.class]) {
            *error = [NSString stringWithFormat:@"@keys: %@ isn't a dictionary", DYIDisplayClassName(object)];
            return nil;
        }
        return [[object allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] compare:[b description]];
        }];
    }
    if ([name hasPrefix:@"@"]) { *error = [NSString stringWithFormat:@"%@: only @count, @keys and @class", name]; return nil; }
    if ([object isKindOfClass:NSDictionary.class] && [object objectForKey:name]) return [object objectForKey:name];
    if (DYIIsCollection(object) && !DYIFindProperty(object, name)) {
        NSMutableArray *mapped = [NSMutableArray array];
        for (id element in DYIElements(object)) {
            NSString *inner = nil;
            id v = DYIStepInto(element, step, &inner);
            if (inner) { *error = inner; return nil; }
            [mapped addObject:v ?: NSNull.null];
        }
        return mapped;
    }
    return DYIProperty(object, name, error);
}

#pragma mark - Formatting

static NSString *DYIOneLine(NSString *s, NSUInteger max) {
    s = [[s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    return s.length > max ? [[s substringToIndex:max] stringByAppendingString:@"…"] : s;
}

static NSString *DYIShortValue(id v) {
    if (!v || v == (id)NSNull.null) return @"nil";
    if (object_isClass(v)) return [NSString stringWithFormat:@"class %@", NSStringFromClass(v)];
    if ([v isKindOfClass:NSString.class]) return [NSString stringWithFormat:@"\"%@\"", DYIOneLine(v, 300)];
    if ([v isKindOfClass:NSAttributedString.class]) return [NSString stringWithFormat:@"\"%@\" (attributed)", DYIOneLine([v string], 300)];
    if ([v isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) return [v boolValue] ? @"YES" : @"NO";
        if (strcmp([v objCType], "c") == 0 || strcmp([v objCType], "B") == 0) return [v boolValue] ? @"YES" : @"NO";
        return [v stringValue];
    }
    if ([v isKindOfClass:NSValue.class]) {
        const char *t = [v objCType];
        if (strcmp(t, @encode(NSRect)) == 0) { NSRect r = [v rectValue]; return [NSString stringWithFormat:@"%g,%g %gx%g", r.origin.x, r.origin.y, r.size.width, r.size.height]; }
        if (strcmp(t, @encode(NSPoint)) == 0) { NSPoint p = [v pointValue]; return [NSString stringWithFormat:@"%g,%g", p.x, p.y]; }
        if (strcmp(t, @encode(NSSize)) == 0) { NSSize s = [v sizeValue]; return [NSString stringWithFormat:@"%gx%g", s.width, s.height]; }
        if (strcmp(t, @encode(NSRange)) == 0) { NSRange r = [v rangeValue]; return [NSString stringWithFormat:@"{%lu, %lu}", (unsigned long)r.location, (unsigned long)r.length]; }
        if (strcmp(t, @encode(NSEdgeInsets)) == 0) { NSEdgeInsets e = [v edgeInsetsValue]; return [NSString stringWithFormat:@"top %g left %g bottom %g right %g", e.top, e.left, e.bottom, e.right]; }
        return DYIOneLine([v description], 300);
    }
    if ([v isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:@"%lu keys", (unsigned long)[v count]];
    if (DYIIsCollection(v)) return [NSString stringWithFormat:@"%lu items", (unsigned long)[v count]];
    if ([v isKindOfClass:NSData.class]) return [NSString stringWithFormat:@"%lu bytes", (unsigned long)[v length]];
    if ([v isKindOfClass:NSURL.class]) return [v absoluteString];
    if ([v isKindOfClass:NSDate.class]) return [v description];
    NSString *head = [NSString stringWithFormat:@"<%@ %p>", DYIDisplayClassName(v), (__bridge void *)v];
    if ([v isKindOfClass:NSView.class]) {
        NSRect f = [v frame];
        head = [head stringByAppendingFormat:@" frame %g,%g %gx%g", f.origin.x, f.origin.y, f.size.width, f.size.height];
    } else if ([v isKindOfClass:NSWindow.class]) {
        head = [head stringByAppendingFormat:@" \"%@\"", DYIOneLine([v title], 80)];
    } else if ([v isKindOfClass:NSMenuItem.class]) {
        head = [head stringByAppendingFormat:@" \"%@\"", DYIOneLine([v title], 80)];
    }
    return head;
}

/// The value as lines: one for a single value; for a collection a count, then an entry per element (at most 200).
static NSArray<NSString *> *DYIValueLines(id v) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    const NSUInteger limit = 200;
    if ([v isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = v;
        [lines addObject:[NSString stringWithFormat:@"%lu keys", (unsigned long)d.count]];
        NSArray *keys = [d.allKeys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) { return [[a description] compare:[b description]]; }];
        for (id k in keys) {
            if (lines.count > limit) { [lines addObject:@"…"]; break; }
            [lines addObject:[NSString stringWithFormat:@"  %@ = %@", DYIOneLine([k description], 120), DYIShortValue(d[k])]];
        }
        return lines;
    }
    if (DYIIsCollection(v)) {
        NSArray *items = DYIElements(v);
        [lines addObject:[NSString stringWithFormat:@"%lu items", (unsigned long)items.count]];
        [items enumerateObjectsUsingBlock:^(id item, NSUInteger i, BOOL *stop) {
            if (i >= limit) { [lines addObject:@"…"]; *stop = YES; return; }
            [lines addObject:[NSString stringWithFormat:@"  [%lu] %@", (unsigned long)i, DYIShortValue(item)]];
        }];
        return lines;
    }
    [lines addObject:DYIShortValue(v)];
    return lines;
}

NSArray<NSString *> *DYIEvaluate(NSString *path, NSString **error) {
    *error = nil;
    NSArray<DYIStep *> *steps = DYIParse(path, error);
    if (!steps) return nil;
    NSString *rootName = steps.firstObject.text;
    id value;
    if ([rootName isEqualToString:@"NSApp"] || [rootName isEqualToString:@"app"]) {
        value = NSApp;
    } else {
        value = NSClassFromString(rootName);
        if (!value) {
            *error = [NSString stringWithFormat:@"%@: start with NSApp or a class this app has", rootName];
            return nil;
        }
    }
    @try {
        for (NSUInteger i = 1; i < steps.count; i++) {
            value = DYIStepInto(value, steps[i], error);
            if (*error) return nil;
        }
    } @catch (NSException *e) {
        *error = [NSString stringWithFormat:@"%@: %@", e.name, DYIOneLine(e.reason ?: @"", 300)];
        return nil;
    }
    return DYIValueLines(value);
}
