#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

static id AXAttribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static NSString *AXString(AXUIElementRef element, CFStringRef name) {
    id value = AXAttribute(element, name);
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return @"";
}

static NSDictionary *AXRecord(AXUIElementRef element, NSInteger depth) {
    id enabled = AXAttribute(element, kAXEnabledAttribute);
    return @{
        @"role": AXString(element, kAXRoleAttribute),
        @"title": AXString(element, kAXTitleAttribute),
        @"description": AXString(element, kAXDescriptionAttribute),
        @"value": AXString(element, kAXValueAttribute),
        @"identifier": AXString(element, kAXIdentifierAttribute),
        @"enabled": [enabled isKindOfClass:[NSNumber class]] ? enabled : [NSNull null],
        @"depth": @(depth),
    };
}

static NSArray<NSDictionary *> *AXFlatten(AXUIElementRef root) {
    NSMutableArray<NSDictionary *> *output = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *stack = [NSMutableArray arrayWithObject:@{
        @"element": (__bridge id)root, @"depth": @0
    }];
    while (stack.count && output.count < 5000) {
        NSDictionary *entry = stack.lastObject;
        [stack removeLastObject];
        AXUIElementRef element = (__bridge AXUIElementRef)entry[@"element"];
        NSInteger depth = [entry[@"depth"] integerValue];
        [output addObject:@{@"element": (__bridge id)element, @"record": AXRecord(element, depth)}];
        if (depth >= 16) continue;
        id children = AXAttribute(element, kAXChildrenAttribute);
        if (![children isKindOfClass:[NSArray class]]) continue;
        for (id child in [(NSArray *)children reverseObjectEnumerator]) {
            [stack addObject:@{@"element": child, @"depth": @(depth + 1)}];
        }
    }
    return output;
}

static NSRunningApplication *RunningApplication(NSString *executable) {
    NSString *expected = [NSURL fileURLWithPath:executable].URLByStandardizingPath.path;
    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
        if (!application.terminated && [application.executableURL.URLByStandardizingPath.path isEqualToString:expected]) return application;
    }
    return nil;
}

static NSRunningApplication *WaitApplication(NSString *executable, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        NSRunningApplication *application = RunningApplication(executable);
        if (application) return application;
        [NSThread sleepForTimeInterval:0.1];
    } while ([deadline timeIntervalSinceNow] > 0);
    return nil;
}

static BOOL RecordMatches(NSDictionary *record, NSString *query) {
    for (NSString *key in @[@"title", @"description", @"value", @"identifier"]) {
        if ([record[key] rangeOfString:query options:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL RecordExactlyMatches(NSDictionary *record, NSString *query) {
    for (NSString *key in @[@"title", @"description", @"value", @"identifier"]) {
        if ([record[key] compare:query options:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)] == NSOrderedSame) return YES;
    }
    return NO;
}

static NSDictionary *WaitElement(NSString *executable, NSString *query, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        NSRunningApplication *application = RunningApplication(executable);
        if (application) {
            AXUIElementRef root = AXUIElementCreateApplication(application.processIdentifier);
            id focusedWindow = AXAttribute(root, kAXFocusedWindowAttribute);
            AXUIElementRef searchRoot = focusedWindow ? (__bridge AXUIElementRef)focusedWindow : root;
            NSArray *elements = AXFlatten(searchRoot);
            CFRelease(root);
            for (NSDictionary *entry in elements) if (RecordMatches(entry[@"record"], query)) return entry;
        }
        [NSThread sleepForTimeInterval:0.2];
    } while ([deadline timeIntervalSinceNow] > 0);
    return nil;
}

static void Fail(NSString *message, int status) {
    fprintf(stderr, "ERROR: %s\n", message.UTF8String);
    exit(status);
}

static void WriteTree(NSString *executable, NSString *destination) {
    NSRunningApplication *application = WaitApplication(executable, 10);
    if (!application) Fail([@"Timed out waiting for application: " stringByAppendingString:executable], 1);
    AXUIElementRef root = AXUIElementCreateApplication(application.processIdentifier);
    NSMutableArray *records = [NSMutableArray array];
    for (NSDictionary *entry in AXFlatten(root)) [records addObject:entry[@"record"]];
    CFRelease(root);
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:records options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToFile:destination options:NSDataWritingAtomic error:&error]) Fail(error.localizedDescription, 1);
    printf("elements=%lu destination=%s\n", (unsigned long)records.count, destination.UTF8String);
}

static void PressElement(NSString *executable, NSString *context, NSString *query, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSDictionary *entry = nil;
    do {
        NSRunningApplication *application = RunningApplication(executable);
        if (application) {
            AXUIElementRef root = AXUIElementCreateApplication(application.processIdentifier);
            id focusedWindow = AXAttribute(root, kAXFocusedWindowAttribute);
            AXUIElementRef searchRoot = focusedWindow ? (__bridge AXUIElementRef)focusedWindow : root;
            NSArray *elements = AXFlatten(searchRoot);
            CFRelease(root);
            if (context.length) {
                NSDictionary *contextEntry = nil;
                for (NSDictionary *candidateEntry in elements) {
                    if (RecordMatches(candidateEntry[@"record"], context)) {
                        contextEntry = candidateEntry;
                        break;
                    }
                }
                if (!contextEntry) {
                    [NSThread sleepForTimeInterval:0.2];
                    continue;
                }
                elements = AXFlatten((__bridge AXUIElementRef)contextEntry[@"element"]);
            }
            for (NSInteger pass = 0; pass < 2 && !entry; pass++) {
                for (NSDictionary *candidateEntry in elements) {
                    BOOL matches = pass == 0 ? RecordExactlyMatches(candidateEntry[@"record"], query) : RecordMatches(candidateEntry[@"record"], query);
                    if (!matches) continue;
                    AXUIElementRef element = (__bridge AXUIElementRef)candidateEntry[@"element"];
                    CFArrayRef actionNames = NULL;
                    BOOL pressable = AXUIElementCopyActionNames(element, &actionNames) == kAXErrorSuccess &&
                        CFArrayContainsValue(actionNames, CFRangeMake(0, CFArrayGetCount(actionNames)), kAXPressAction);
                    if (actionNames) CFRelease(actionNames);
                    if (pressable) { entry = candidateEntry; break; }
                    if (!entry) entry = candidateEntry;
                }
            }
            if (entry) break;
        }
        [NSThread sleepForTimeInterval:0.2];
    } while ([deadline timeIntervalSinceNow] > 0);
    if (!entry) Fail([@"Timed out waiting for accessibility text: " stringByAppendingString:query], 1);
    AXUIElementRef candidate = (__bridge AXUIElementRef)entry[@"element"];
    CFRetain(candidate);
    while (candidate) {
        CFArrayRef actionNames = NULL;
        BOOL pressable = AXUIElementCopyActionNames(candidate, &actionNames) == kAXErrorSuccess &&
            CFArrayContainsValue(actionNames, CFRangeMake(0, CFArrayGetCount(actionNames)), kAXPressAction);
        if (actionNames) CFRelease(actionNames);
        if (pressable) {
            AXError result = AXUIElementPerformAction(candidate, kAXPressAction);
            CFRelease(candidate);
            if (result != kAXErrorSuccess) Fail([NSString stringWithFormat:@"AXPress failed for %@: %d", query, result], 1);
            printf("pressed=%s role=%s\n", query.UTF8String, [entry[@"record"][@"role"] UTF8String]);
            return;
        }
        CFTypeRef parent = NULL;
        AXUIElementCopyAttributeValue(candidate, kAXParentAttribute, &parent);
        CFRelease(candidate);
        candidate = parent ? (AXUIElementRef)parent : NULL;
    }
    Fail([@"No pressable accessibility ancestor for: " stringByAppendingString:query], 1);
}

static NSInteger WindowCount(NSString *executable) {
    NSRunningApplication *application = RunningApplication(executable);
    if (!application) return 0;
    AXUIElementRef root = AXUIElementCreateApplication(application.processIdentifier);
    id windows = AXAttribute(root, kAXWindowsAttribute);
    CFRelease(root);
    return [windows isKindOfClass:[NSArray class]] ? [windows count] : 0;
}

static void WaitWindows(NSString *executable, NSInteger count, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        if (WindowCount(executable) >= count) { printf("windows>=%ld\n", (long)count); return; }
        [NSThread sleepForTimeInterval:0.2];
    } while ([deadline timeIntervalSinceNow] > 0);
    Fail([NSString stringWithFormat:@"Timed out waiting for %ld windows", (long)count], 1);
}

static void CaptureWindows(NSString *executable, NSString *directory) {
    if (!CGPreflightScreenCaptureAccess()) Fail(@"Screen Recording permission is not granted", 1);
    NSRunningApplication *application = WaitApplication(executable, 10);
    if (!application) Fail([@"Timed out waiting for application: " stringByAppendingString:executable], 1);
    [application activateWithOptions:0];
    [NSThread sleepForTimeInterval:0.2];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSInteger captured = 0;
    for (NSDictionary *window in windows) {
        if ([window[(NSString *)kCGWindowOwnerPID] intValue] != application.processIdentifier) continue;
        if ([window[(NSString *)kCGWindowLayer] integerValue] != 0) continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(NSString *)kCGWindowBounds], &bounds) || bounds.size.width < 1 || bounds.size.height < 1) continue;
        NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"window-%ld.png", (long)(captured + 1)]];
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
        task.arguments = @[@"-x", @"-l", [window[(NSString *)kCGWindowNumber] stringValue], path];
        NSError *error = nil;
        if (![task launchAndReturnError:&error]) Fail(error.localizedDescription, 1);
        [task waitUntilExit];
        if (task.terminationStatus != 0) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            continue;
        }
        captured += 1;
    }
    if (!captured) Fail(@"No visible lab application windows were captured", 1);
    printf("screenshots=%ld directory=%s\n", (long)captured, directory.UTF8String);
}

static CGKeyCode KeyCode(NSString *name) {
    NSDictionary<NSString *, NSNumber *> *codes = @{
        @"return": @36, @"enter": @36, @"g": @5, @"v": @9,
        @"equal": @24, @"plus": @24, @"minus": @27, @"0": @29,
    };
    NSNumber *code = codes[name.lowercaseString];
    if (!code) Fail([@"Unsupported key: " stringByAppendingString:name], 2);
    return (CGKeyCode)code.unsignedShortValue;
}

static CGEventFlags ModifierFlags(NSString *value) {
    CGEventFlags flags = 0;
    for (NSString *name in [value.lowercaseString componentsSeparatedByString:@","]) {
        if (!name.length || [name isEqualToString:@"none"]) continue;
        if ([name isEqualToString:@"cmd"] || [name isEqualToString:@"command"]) flags |= kCGEventFlagMaskCommand;
        else if ([name isEqualToString:@"shift"]) flags |= kCGEventFlagMaskShift;
        else if ([name isEqualToString:@"ctrl"] || [name isEqualToString:@"control"]) flags |= kCGEventFlagMaskControl;
        else if ([name isEqualToString:@"option"] || [name isEqualToString:@"alt"]) flags |= kCGEventFlagMaskAlternate;
        else Fail([@"Unsupported modifier: " stringByAppendingString:name], 2);
    }
    return flags;
}

static void SendKey(NSString *executable, NSString *name, NSString *modifiers) {
    NSRunningApplication *application = WaitApplication(executable, 10);
    if (!application) Fail([@"Timed out waiting for application: " stringByAppendingString:executable], 1);
    [application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    [NSThread sleepForTimeInterval:0.15];
    CGKeyCode code = KeyCode(name);
    CGEventFlags flags = ModifierFlags(modifiers);
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, code, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, code, false);
    if (!down || !up) Fail(@"Could not create keyboard event", 1);
    CGEventSetFlags(down, flags);
    CGEventSetFlags(up, flags);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    printf("key=%s modifiers=%s\n", name.UTF8String, modifiers.UTF8String);
}

static void Usage(void) {
    fputs("Usage: omnideck-lab-driver preflight [--prompt] | wait APP TIMEOUT | wait-text APP TEXT TIMEOUT | click APP TEXT TIMEOUT | click-in APP CONTEXT TEXT TIMEOUT | key APP KEY MODIFIERS | wait-windows APP COUNT TIMEOUT | dump APP FILE | screenshot APP DIR\n", stderr);
    exit(2);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) Usage();
        NSString *command = @(argv[1]);
        if ([command isEqualToString:@"preflight"]) {
            BOOL prompt = argc == 3 && [@(argv[2]) isEqualToString:@"--prompt"];
            NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @(prompt)};
            BOOL accessibility = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
            BOOL screen = prompt ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess();
            printf("accessibility=%s screenRecording=%s\n", accessibility ? "true" : "false", screen ? "true" : "false");
            return accessibility && screen ? 0 : 3;
        }
        if ([command isEqualToString:@"wait"] && argc == 4) {
            NSRunningApplication *application = WaitApplication(@(argv[2]), [@(argv[3]) doubleValue]);
            if (!application) Fail([@"Timed out waiting for application: " stringByAppendingString:@(argv[2])], 1);
            printf("pid=%d\n", application.processIdentifier);
            return 0;
        }
        if ([command isEqualToString:@"wait-text"] && argc == 5) {
            NSDictionary *entry = WaitElement(@(argv[2]), @(argv[3]), [@(argv[4]) doubleValue]);
            if (!entry) Fail([@"Timed out waiting for accessibility text: " stringByAppendingString:@(argv[3])], 1);
            printf("found=%s role=%s\n", argv[3], [entry[@"record"][@"role"] UTF8String]);
            return 0;
        }
        if ([command isEqualToString:@"click"] && argc == 5) { PressElement(@(argv[2]), nil, @(argv[3]), [@(argv[4]) doubleValue]); return 0; }
        if ([command isEqualToString:@"click-in"] && argc == 6) { PressElement(@(argv[2]), @(argv[3]), @(argv[4]), [@(argv[5]) doubleValue]); return 0; }
        if ([command isEqualToString:@"key"] && argc == 5) { SendKey(@(argv[2]), @(argv[3]), @(argv[4])); return 0; }
        if ([command isEqualToString:@"wait-windows"] && argc == 5) { WaitWindows(@(argv[2]), [@(argv[3]) integerValue], [@(argv[4]) doubleValue]); return 0; }
        if ([command isEqualToString:@"dump"] && argc == 4) { WriteTree(@(argv[2]), @(argv[3])); return 0; }
        if ([command isEqualToString:@"screenshot"] && argc == 4) { CaptureWindows(@(argv[2]), @(argv[3])); return 0; }
        Usage();
    }
}
