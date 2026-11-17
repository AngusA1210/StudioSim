// See plugin_panel_mac.h.

#import "plugin_panel_mac.h"

namespace {

// Whether what has the keyboard in a window is being typed into: a text box of the system's own (or its field
// editor), or a view of the plug-in's own that takes text through the system's text input and has a place in some
// text just now (JUCE's views report none, NSNotFound, unless one of its text boxes has the focus).
bool typingInto(id responder) {
    if ([responder isKindOfClass:[NSTextView class]] || [responder isKindOfClass:[NSTextField class]]) return true;
    if ([responder conformsToProtocol:@protocol(NSTextInputClient)] && [responder respondsToSelector:@selector(selectedRange)])
        return [(id<NSTextInputClient>)responder selectedRange].location != NSNotFound;
    return false;
}

// Whether a view clicked is a text box of the system's own that can be typed into.
bool textBox(NSView* view) {
    if ([view isKindOfClass:[NSTextView class]]) return ((NSTextView*)view).isEditable;
    if ([view isKindOfClass:[NSTextField class]]) return ((NSTextField*)view).isEditable;
    return false;
}

}  // namespace

@implementation SRPluginPanel {
    BOOL _mayType;  // while something in it is typed into (or a text box of the system's own is clicked): it may have the keyboard
    NSTimer* _watch;
}

+ (instancetype)panelWithSize:(NSSize)size {
    SRPluginPanel* panel = [[SRPluginPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                                      NSWindowStyleMaskMiniaturizable
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO];
    panel.becomesKeyOnlyIfNeeded = YES;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.level = NSFloatingWindowLevel;  // above the game, full screen or not, on whichever space it is on
    panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace;
    // A box to type in can open some time after a click (from a menu, say): looked for a few times a second.
    __weak SRPluginPanel* watched = panel;
    panel->_watch = [NSTimer timerWithTimeInterval:0.25
                                           repeats:YES
                                             block:^(NSTimer*) {
                                               [watched settleKeyboard];
                                             }];
    [[NSRunLoop mainRunLoop] addTimer:panel->_watch forMode:NSRunLoopCommonModes];
    return panel;
}

- (void)dealloc {
    [_watch invalidate];
}

- (BOOL)canBecomeKeyWindow {
    return _mayType;
}

- (void)sendEvent:(NSEvent*)event {
    const NSEventType type = event.type;
    // A click takes the keyboard from the game only for a text box of the system's own, or while something in it is
    // typed into already. Anything else clicked (a knob dragged, a switch) leaves it with the game, though the view
    // asks for it (JUCE's do, every click), so that the notes played from the keyboard go on playing meanwhile. A box
    // a plug-in draws itself takes it once it is found to be typed into, as the click ends (settleKeyboard).
    if (type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown) {
        NSView* hit = [self.contentView hitTest:[self.contentView.superview convertPoint:event.locationInWindow fromView:nil]];
        _mayType = typingInto(self.firstResponder) || textBox(hit);
    }
    [super sendEvent:event];
    if (type == NSEventTypeLeftMouseUp || type == NSEventTypeRightMouseUp || type == NSEventTypeKeyUp)
        dispatch_async(dispatch_get_main_queue(), ^{
          [self settleKeyboard];
        });
}

// The keyboard where it should be: here while something in it is typed into, with the game otherwise.
- (void)settleKeyboard {
    if (!self.visible || !NSApp.active || NSEvent.pressedMouseButtons != 0) return;
    if (typingInto(self.firstResponder)) {
        _mayType = YES;
        if (!self.keyWindow) [self makeKeyWindow];
        return;
    }
    _mayType = NO;
    if (!self.keyWindow) return;
    for (NSWindow* w in NSApp.orderedWindows)  // (back to the game: the frontmost window that isn't a plug-in's)
        if (![w isKindOfClass:[NSPanel class]] && w.visible && w.canBecomeKeyWindow) {
            [w makeKeyWindow];
            break;
        }
}

@end
