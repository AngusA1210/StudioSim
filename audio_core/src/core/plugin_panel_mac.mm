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

}  // namespace

@implementation SRPluginPanel {
    BOOL _mayType;  // while a click goes on in it, or while it is typed into: it may have the keyboard
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
    if (type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown)
        _mayType = YES;  // (whatever it does with the click, it may take the keyboard meanwhile: a box of its own to type in)
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
