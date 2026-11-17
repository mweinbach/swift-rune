#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <stdatomic.h>

// Exercise the app's own Winit NSView without moving the user's pointer or posting system events.
@interface ScrollFixtureEvent : NSObject
@property NSPoint point;
@end

@implementation ScrollFixtureEvent
- (NSPoint)locationInWindow { return self.point; }
- (NSEventModifierFlags)modifierFlags { return 0; }
- (NSEventType)type { return NSEventTypeScrollWheel; }
- (CGFloat)scrollingDeltaX { return 0; }
- (CGFloat)scrollingDeltaY { return -48; }
- (CGFloat)deltaX { return 0; }
- (CGFloat)deltaY { return -48; }
- (BOOL)hasPreciseScrollingDeltas { return YES; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
- (NSEventPhase)phase { return NSEventPhaseChanged; }
- (NSEventPhase)momentumPhase { return NSEventPhaseNone; }
- (NSTimeInterval)timestamp { return CACurrentMediaTime(); }
@end

static _Atomic unsigned submitted;
static id (*previousNextDrawable)(id, SEL);
static FILE *presentations;

unsigned rust_wheels_submitted(void) { return submitted; }

static id nextDrawable(id layer, SEL selector) {
    id<CAMetalDrawable> drawable = previousNextDrawable(layer, selector);
    if (drawable) {
        // The benchmark posts wheels and acquires the window drawable on the main thread.
        unsigned step = submitted;
        NSUInteger width = drawable.texture.width, height = drawable.texture.height;
        [drawable addPresentedHandler:^(id<MTLDrawable> completed) {
            fprintf(presentations, "%u,%lu,%lu,%.12f\n", step, (unsigned long)width,
                    (unsigned long)height, completed.presentedTime);
        }];
    }
    return drawable;
}

void rust_observe_presentations(const char *path) {
    presentations = fopen(path, "w");
    if (!presentations) { perror(path); exit(1); }
    setvbuf(presentations, NULL, _IOLBF, 0);
    fputs("wheel,width_px,height_px,presented_seconds\n", presentations);
    Method method = class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable));
    previousNextDrawable = (void *)method_setImplementation(method, (IMP)nextDrawable);
}

static NSView *winitView(NSView *view) {
    if ([NSStringFromClass(view.class) containsString:@"WinitView"]) return view;
    for (NSView *child in view.subviews) {
        NSView *found = winitView(child);
        if (found) return found;
    }
    return nil;
}

void rust_wheel(void) {
    // Let the first window appear before measuring its first wheel.
    int delay = submitted ? 1 : 200;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSView *target = nil;
        for (NSWindow *window in NSApp.windows) {
            if (window.visible && [window.title hasPrefix:@"Rune Rust Large "]) {
                target = winitView(window.contentView);
                break;
            }
        }
        if (!target) { fputs("Could not find the benchmark's Winit view\n", stderr); exit(1); }
        ScrollFixtureEvent *event = [ScrollFixtureEvent new];
        event.point = [target convertPoint:NSMakePoint(NSMidX(target.bounds), NSMidY(target.bounds)) toView:nil];
        [target scrollWheel:(NSEvent *)event];
        submitted++;
    });
}

void rust_finish(void (*callback)(void *), void *context) {
    // Presentation callbacks can arrive after the final encode report.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        callback(context);
    });
}
