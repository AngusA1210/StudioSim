// The checks of a plug-in's window on a Mac (src/core/plugin_panel_mac.h): who has the keyboard as it is clicked. A
// window stands in for the game's, and three views for what plug-ins draw in theirs: a knob that asks for the keyboard
// on every click (as JUCE's views do), a text box of the system's own, and a box a plug-in draws itself and types into
// through the system's text input. Clicks and keys are handed to the app as the system would hand them.
// Run: audio_core/build/plugin_panel_tests (two windows come up for a second or two; it needs to be the active app,
// and says so if it can't be).

#import <AppKit/AppKit.h>

#include <cstdio>
#include <string>

#import "plugin_panel_mac.h"

namespace {

int failures = 0;

void check(bool ok, const std::string& what, const std::string& detail) {
    std::printf("  [%s] %s  (%s)\n", ok ? "pass" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++failures;
}

}  // namespace

// The game's window: what it is given of the keyboard.
@interface SRGameView : NSView
@property(nonatomic) int keys;
@end
@implementation SRGameView
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (void)keyDown:(NSEvent*)event {
    ++self.keys;
}
- (void)keyUp:(NSEvent*)event {
}
@end

// A knob, as a JUCE plug-in's view is: it would have the panel take the keyboard for any click on it.
@interface SRKnobView : NSView
@property(nonatomic) int drags;
@end
@implementation SRKnobView
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return YES;
}
- (BOOL)needsPanelToBecomeKey {
    return YES;
}
- (void)mouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];
}
- (void)mouseDragged:(NSEvent*)event {
    ++self.drags;
}
@end

// A box a plug-in draws itself: it has a place in some text (as the system's text input asks) only while it is typed
// into, from a click on it until `typing` is put back.
@interface SRDrawnBox : NSView <NSTextInputClient>
@property(nonatomic) BOOL typing;
@property(nonatomic) int keys;
@end
@implementation SRDrawnBox
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent*)event {
    return YES;
}
- (BOOL)needsPanelToBecomeKey {
    return YES;
}
- (void)mouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];
    self.typing = YES;
}
- (void)keyDown:(NSEvent*)event {
    ++self.keys;
}
- (NSRange)selectedRange {
    return self.typing ? NSMakeRange(0, 0) : NSMakeRange(NSNotFound, 0);
}
- (void)insertText:(id)string replacementRange:(NSRange)range {
}
- (void)setMarkedText:(id)string selectedRange:(NSRange)selected replacementRange:(NSRange)range {
}
- (void)unmarkText {
}
- (NSRange)markedRange {
    return NSMakeRange(NSNotFound, 0);
}
- (BOOL)hasMarkedText {
    return NO;
}
- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual {
    return nil;
}
- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
    return @[];
}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
    return NSZeroRect;
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return 0;
}
- (void)doCommandBySelector:(SEL)selector {
}
@end

namespace {

NSWindow* game = nil;
SRPluginPanel* panel = nil;

// The app's events for a while, as the game's loop takes them (and the panel's timer and what it puts off meanwhile).
void pump(double seconds) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES])
        [NSApp sendEvent:event];
}

NSEvent* mouse(NSEventType type, NSView* on) {
    const NSPoint at = [on convertPoint:NSMakePoint(NSMidX(on.bounds), NSMidY(on.bounds)) toView:nil];
    return [NSEvent mouseEventWithType:type location:at modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                          windowNumber:panel.windowNumber context:nil eventNumber:0 clickCount:1
                              pressure:type == NSEventTypeLeftMouseUp ? 0.0f : 1.0f];
}

NSEvent* key(NSEventType type) {  // the A key, which plays a note in the game
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                        windowNumber:NSApp.keyWindow.windowNumber context:nil characters:@"a" charactersIgnoringModifiers:@"a"
                           isARepeat:NO keyCode:0];
}

const char* keyHolder() {
    return NSApp.keyWindow == game ? "the game" : NSApp.keyWindow == panel ? "the plug-in's window" : "nothing";
}

}  // namespace

int main() {
    @autoreleasepool {
        std::printf("StudioSim: a plug-in's window and the keyboard\n");
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
        [NSApp finishLaunching];

        game = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 640, 420) styleMask:NSWindowStyleMaskTitled
                                             backing:NSBackingStoreBuffered defer:NO];
        game.title = @"The game (a check)";
        SRGameView* game_view = [[SRGameView alloc] initWithFrame:NSMakeRect(0, 0, 640, 420)];
        game.contentView = game_view;
        [game makeKeyAndOrderFront:nil];
        [game makeFirstResponder:game_view];

        panel = [SRPluginPanel panelWithSize:NSMakeSize(420, 120)];
        panel.title = @"A plug-in (a check)";
        NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 120)];
        SRKnobView* knob = [[SRKnobView alloc] initWithFrame:NSMakeRect(10, 10, 100, 100)];
        NSTextField* field = [NSTextField textFieldWithString:@"Preset"];
        field.frame = NSMakeRect(120, 45, 140, 24);
        SRDrawnBox* drawn = [[SRDrawnBox alloc] initWithFrame:NSMakeRect(270, 10, 140, 100)];
        for (NSView* v in @[knob, field, drawn]) [content addSubview:v];
        panel.contentView = content;
        [panel setFrameTopLeftPoint:NSMakePoint(NSMaxX(game.frame) + 10, NSMaxY(game.frame))];
        [panel orderFront:nil];

        [NSApp activateIgnoringOtherApps:YES];
        for (int i = 0; i < 30 && !(NSApp.active && NSApp.keyWindow == game); ++i) pump(0.1);
        if (!NSApp.active || NSApp.keyWindow != game) {
            std::printf("  (skipped: macOS wouldn't make the checks the active app; run them again from a terminal in front)\n");
            return 0;
        }

        // A knob turned while a note is held: the keyboard stays with the game all the while, its notes still played.
        std::printf("\nA knob turned while the keyboard plays\n");
        [NSApp sendEvent:key(NSEventTypeKeyDown)];
        [NSApp sendEvent:mouse(NSEventTypeLeftMouseDown, knob)];
        const char* clicked = keyHolder();
        for (int i = 0; i < 5; ++i) [NSApp sendEvent:mouse(NSEventTypeLeftMouseDragged, knob)];
        const int before = game_view.keys;
        [NSApp sendEvent:key(NSEventTypeKeyUp)];
        [NSApp sendEvent:key(NSEventTypeKeyDown)];
        const bool played = game_view.keys == before + 1;
        [NSApp sendEvent:mouse(NSEventTypeLeftMouseUp, knob)];
        [NSApp sendEvent:key(NSEventTypeKeyUp)];
        pump(0.1);
        check(std::string(clicked) == "the game" && NSApp.keyWindow == game && knob.drags == 5,
              "a knob in a plug-in's window turns as it is dragged, the keyboard left with the game (though the knob asks for it)",
              std::string("on the click, the keyboard with ") + clicked + ", " + std::to_string(knob.drags) + " drags");
        check(played && game_view.keys == 2, "a note key pressed while the knob is held plays in the game",
              std::to_string(game_view.keys) + " of 2 notes reached the game");

        // A text box of the system's own takes the keyboard when it is clicked, and gives it back once it is done with.
        std::printf("\nTyping in a plug-in's window\n");
        [NSApp postEvent:mouse(NSEventTypeLeftMouseUp, field) atStart:NO];  // (waiting: the box follows the click till it ends)
        [NSApp sendEvent:mouse(NSEventTypeLeftMouseDown, field)];
        pump(0.1);
        const char* field_has = keyHolder();
        [panel makeFirstResponder:knob];  // (typed into and done with)
        pump(0.4);
        check(std::string(field_has) == "the plug-in's window" && NSApp.keyWindow == game,
              "a text box of the system's own takes the keyboard as it is clicked, and gives it back to the game once it is done with",
              std::string("clicked: ") + field_has + "; after: " + keyHolder());

        // A box the plug-in draws itself: the keyboard goes to it once it is seen to be typed into, the click over.
        [NSApp sendEvent:mouse(NSEventTypeLeftMouseDown, drawn)];
        const char* drawn_click = keyHolder();
        [NSApp sendEvent:mouse(NSEventTypeLeftMouseUp, drawn)];
        pump(0.1);
        const char* drawn_has = keyHolder();
        const int game_before = game_view.keys;
        [NSApp sendEvent:key(NSEventTypeKeyDown)];
        [NSApp sendEvent:key(NSEventTypeKeyUp)];
        const int typed = drawn.keys, game_keys = game_view.keys - game_before;
        drawn.typing = NO;  // (typing done: Return pressed, say)
        pump(0.4);
        check(std::string(drawn_has) == "the plug-in's window" && typed == 1 && game_keys == 0,
              "a box a plug-in draws itself takes the keyboard once it is typed into, the keys typed going to it and not the game",
              std::string("on the click, the keyboard with ") + drawn_click + "; after it, with " + drawn_has + ", " +
                  std::to_string(typed) + " key typed into it");
        check(NSApp.keyWindow == game, "and gives it back to the game once the typing is done", std::string("now with ") + keyHolder());

        [panel orderOut:nil];
        [game orderOut:nil];
        std::printf("\n%s\n", failures ? "SOME CHECKS FAILED" : "All checks passed");
        return failures ? 1 : 0;
    }
}
