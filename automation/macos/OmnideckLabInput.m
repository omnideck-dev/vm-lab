#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

static id InputAttribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static NSString *InputString(AXUIElementRef element, CFStringRef name) {
    id value = InputAttribute(element, name);
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static BOOL InputMatches(AXUIElementRef element, NSString *query) {
    for (NSString *value in @[
        InputString(element, kAXTitleAttribute),
        InputString(element, kAXDescriptionAttribute),
        InputString(element, kAXValueAttribute),
        InputString(element, kAXIdentifierAttribute),
    ]) {
        if ([value rangeOfString:query options:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)].location != NSNotFound) return YES;
    }
    return NO;
}

static AXUIElementRef InputFind(AXUIElementRef root, NSString *query) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:(__bridge id)root];
    NSInteger visited = 0;
    while (stack.count && visited++ < 5000) {
        id storedElement = stack.lastObject;
        AXUIElementRef element = (__bridge AXUIElementRef)storedElement;
        [stack removeLastObject];
        if (InputMatches(element, query)) {
            CFRetain(element);
            return element;
        }
        id children = InputAttribute(element, kAXChildrenAttribute);
        if (![children isKindOfClass:[NSArray class]]) continue;
        for (id child in [(NSArray *)children reverseObjectEnumerator]) [stack addObject:child];
    }
    return NULL;
}

__attribute__((constructor)) static void OmnideckLabInput(void) {
    @autoreleasepool {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *target = environment[@"OMNIDECK_LAB_INPUT_TARGET"];
        NSString *query = environment[@"OMNIDECK_LAB_INPUT_CLICK"];
        if (!target.length || !query.length) return;

        NSString *expected = [NSURL fileURLWithPath:target].URLByStandardizingPath.path;
        NSRunningApplication *application = nil;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        do {
            for (NSRunningApplication *candidate in NSWorkspace.sharedWorkspace.runningApplications) {
                if (!candidate.terminated && [candidate.executableURL.URLByStandardizingPath.path isEqualToString:expected]) {
                    application = candidate;
                    break;
                }
            }
            if (!application) [NSThread sleepForTimeInterval:0.1];
        } while (!application && deadline.timeIntervalSinceNow > 0);
        if (!application) return;

        [application activateWithOptions:0];
        [NSThread sleepForTimeInterval:0.2];
        AXUIElementRef root = AXUIElementCreateApplication(application.processIdentifier);
        id focusedWindow = InputAttribute(root, kAXFocusedWindowAttribute);
        AXUIElementRef searchRoot = focusedWindow ? (__bridge AXUIElementRef)focusedWindow : root;
        AXUIElementRef element = InputFind(searchRoot, query);
        CFRelease(root);
        if (!element) return;

        id positionValue = InputAttribute(element, kAXPositionAttribute);
        id sizeValue = InputAttribute(element, kAXSizeAttribute);
        CGPoint position = CGPointZero;
        CGSize size = CGSizeZero;
        BOOL positioned = positionValue && CFGetTypeID((__bridge CFTypeRef)positionValue) == AXValueGetTypeID();
        BOOL sized = sizeValue && CFGetTypeID((__bridge CFTypeRef)sizeValue) == AXValueGetTypeID();
        if (positioned) AXValueGetValue((__bridge AXValueRef)positionValue, kAXValueTypeCGPoint, &position);
        if (sized) AXValueGetValue((__bridge AXValueRef)sizeValue, kAXValueTypeCGSize, &size);
        CFRelease(element);
        if (!positioned || !sized || size.width < 1 || size.height < 1) return;

        CGPoint point = CGPointMake(position.x + size.width / 2.0, position.y + size.height / 2.0);
        CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, kCGMouseButtonLeft);
        CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
        CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
        if (move && down && up) {
            CGEventPost(kCGHIDEventTap, move);
            CGEventPost(kCGHIDEventTap, down);
            CGEventPost(kCGHIDEventTap, up);
            [NSThread sleepForTimeInterval:0.2];
        }
        if (move) CFRelease(move);
        if (down) CFRelease(down);
        if (up) CFRelease(up);
    }
}
