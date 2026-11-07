// Test-only library that ci/host-keys.sh builds and UI tests load into the app
// with DYLD_INSERT_LIBRARIES. It never ships. It records hardware key presses
// entering -[UIApplication sendEvent:] and forwards every event untouched.
// An opt-in Darwin notification also activates a requested setup button
// through its public accessibility action while VoiceOver remains enabled.
// Escape always uses the app's own handling.
//
// Each press phase becomes one line "<phase> <HID usage>" (e.g. "began 41" for
// Escape) in the file named by UNIPAD_KEY_ARRIVAL_LOG. A host can say it pressed
// a key while the simulator delivered it to no app; this file is what tells
// "the key never reached the app" apart from "the app got the key and ignored it".

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static IMP originalSendEvent;
static NSString *logPath;
static NSString *navigationNotification;

static NSString *phaseName(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"began";
        case UIPressPhaseChanged: return @"changed";
        case UIPressPhaseStationary: return @"stationary";
        case UIPressPhaseEnded: return @"ended";
        case UIPressPhaseCancelled: return @"cancelled";
    }
    return @"unknown";
}

static void append(NSString *line) {
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!file) {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        file = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    [file seekToEndOfFile];
    [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [file closeFile];
}

// Search the app's public accessibility containers, including SwiftUI's virtual
// elements. Each object is visited once; hidden windows and containers are excluded.
static id navigationElement(id node, NSString *identifier, NSString *label, NSMutableSet *visited) {
    if (!node || [node accessibilityElementsHidden]) return nil;
    if ([node isKindOfClass:UIView.class] && ([node isHidden] || [node alpha] == 0)) return nil;
    NSValue *identity = [NSValue valueWithNonretainedObject:node];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    NSString *nodeIdentifier = [node respondsToSelector:@selector(accessibilityIdentifier)]
        ? [node accessibilityIdentifier] : @"";
    if ([(nodeIdentifier ?: @"") isEqualToString:identifier]
        && [([node accessibilityLabel] ?: @"") isEqualToString:label]
        && ([node accessibilityTraits] & UIAccessibilityTraitButton)) return node;
    NSInteger count = [node accessibilityElementCount];
    if (count != NSNotFound && count > 0 && count <= 1000) {
        for (NSInteger index = 0; index < count; index++) {
            id found = navigationElement([node accessibilityElementAtIndex:index], identifier, label, visited);
            if (found) return found;
        }
    }
    if ([node isKindOfClass:UIView.class]) {
        for (UIView *child in [node subviews]) {
            id found = navigationElement(child, identifier, label, visited);
            if (found) return found;
        }
    }
    return nil;
}

static void activateNavigation(void) {
    NSString *requestPath = [logPath stringByAppendingString:@"-navigation.json"];
    NSData *data = [NSData dataWithContentsOfFile:requestPath];
    if (!data) return; // A duplicate notification has no request left to execute.
    if (![NSFileManager.defaultManager removeItemAtPath:requestPath error:nil]) {
        append(@"navigation could not consume request\nnavigation activated=0\n");
        return;
    }
    id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class]
        || ![request[@"identifier"] isKindOfClass:NSString.class]
        || ![request[@"label"] isKindOfClass:NSString.class]) {
        append(@"navigation invalid request\nnavigation activated=0\n");
        return;
    }
    NSString *identifier = request[@"identifier"], *label = request[@"label"];
    BOOL allowed = [identifier isEqualToString:@"gearshape"]
        || [identifier isEqualToString:@"midi.help.open"]
        || (identifier.length == 0 && ([label isEqualToString:@"Reconnect Launchpad"]
            || [label isEqualToString:@"런치패드 다시 연결하기"]));
    if (!allowed || !UIAccessibilityIsVoiceOverRunning()) {
        append(@"navigation request rejected or VoiceOver disabled\nnavigation activated=0\n");
        return;
    }
    id target = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive
            || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            target = navigationElement(window, identifier, label, [NSMutableSet set]);
            if (target) break;
        }
        if (target) break;
    }
    NSString *actualIdentifier = [target respondsToSelector:@selector(accessibilityIdentifier)]
        ? [target accessibilityIdentifier] : @"";
    NSString *actualLabel = [target accessibilityLabel];
    BOOL matches = target && [(actualIdentifier ?: @"") isEqualToString:identifier]
        && [(actualLabel ?: @"") isEqualToString:label];
    append([NSString stringWithFormat:@"navigation target %@ | %@ allowed=%d\n",
            actualIdentifier ?: @"", actualLabel ?: @"", matches]);
    BOOL activated = matches && [target accessibilityActivate];
    append([NSString stringWithFormat:@"navigation activated=%d\n", activated]);
}

static void navigationRequested(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ activateNavigation(); });
}

static void recordingSendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    // Hardware keyboard events come as a private UIPressesEvent subclass whose
    // type is not UIEventTypePresses.
    if ([event isKindOfClass:[UIPressesEvent class]]) {
        for (UIPress *press in ((UIPressesEvent *)event).allPresses) {
            if (press.key) {
                append([NSString stringWithFormat:@"%@ %ld\n", phaseName(press.phase), (long)press.key.keyCode]);
            }
        }
    }
    ((void (*)(UIApplication *, SEL, UIEvent *))originalSendEvent)(self, _cmd, event);
}

__attribute__((constructor)) static void installProbe(void) {
    logPath = NSProcessInfo.processInfo.environment[@"UNIPAD_KEY_ARRIVAL_LOG"];
    if (logPath.length == 0) return;
    navigationNotification = NSProcessInfo.processInfo.environment[@"UNIPAD_VOICEOVER_NAVIGATION"];
    if (navigationNotification.length) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            navigationRequested, (__bridge CFStringRef)navigationNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    Method sendEvent = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
    originalSendEvent = method_setImplementation(sendEvent, (IMP)recordingSendEvent);
    append(@"loaded\n");
}
