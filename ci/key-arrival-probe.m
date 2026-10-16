// Test-only library that ci/host-keys.sh builds and UI tests load into the app
// with DYLD_INSERT_LIBRARIES. It never ships and never changes the app's own
// handling: it notes every hardware key press that enters the app through
// -[UIApplication sendEvent:], then passes the event on untouched.
//
// Each press phase becomes one line "<phase> <HID usage>" (e.g. "began 41" for
// Escape) in the file named by UNIPAD_KEY_ARRIVAL_LOG. A host can say it pressed
// a key while the simulator delivered it to no app; this file is what tells
// "the key never reached the app" apart from "the app got the key and ignored it".

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static IMP originalSendEvent;
static NSString *logPath;

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
    Method sendEvent = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
    originalSendEvent = method_setImplementation(sendEvent, (IMP)recordingSendEvent);
    append(@"loaded\n");
}
