// A plug-in's window on macOS: a floating panel over the game that never takes the keyboard from it unless something in
// it is being typed into, as the Audio Units' windows are (plugin_host_mac.mm).

#include "plugin_window.h"

#import <AppKit/AppKit.h>

#include <algorithm>

@interface SRPlugViewPanel : NSPanel
@property(nonatomic) BOOL typing;  // a text box in it was clicked last: it may have the keyboard, for that
@end

@implementation SRPlugViewPanel
- (BOOL)canBecomeKeyWindow {
    return self.typing;
}
- (void)sendEvent:(NSEvent*)event {
    if (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown) {
        NSView* hit = [self.contentView hitTest:[self.contentView.superview convertPoint:event.locationInWindow fromView:nil]];
        self.typing = [hit isKindOfClass:[NSTextView class]] || [hit isKindOfClass:[NSTextField class]];
    }
    [super sendEvent:event];
}
@end

// A view the plug-in draws into that is flipped as VST3 views expect (their origin at the top left).
@interface SRPlugViewHolder : NSView
@end

@implementation SRPlugViewHolder
- (BOOL)isFlipped {
    return YES;
}
@end

namespace sr {
namespace {

class MacPluginWindow final : public PluginWindow {
public:
    MacPluginWindow(int width, int height) {
        const NSRect frame = NSMakeRect(0, 0, std::max(width, 120), std::max(height, 60));
        panel_ = [[SRPlugViewPanel alloc] initWithContentRect:frame
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        panel_.becomesKeyOnlyIfNeeded = YES;
        panel_.hidesOnDeactivate = NO;
        panel_.releasedWhenClosed = NO;
        panel_.level = NSFloatingWindowLevel;  // above the game, full screen or not, on whichever space it is on
        panel_.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace;
        holder_ = [[SRPlugViewHolder alloc] initWithFrame:frame];
        panel_.contentView = holder_;
        [panel_ center];
    }

    ~MacPluginWindow() override {
        [panel_ orderOut:nil];
        panel_.contentView = nil;
        holder_ = nil;
        panel_ = nil;
    }

    void* nativeView() override { return (__bridge void*)holder_; }

    void setContentSize(int width, int height) override {
        const NSSize size = NSMakeSize(std::max(width, 60), std::max(height, 30));
        const NSRect frame = panel_.frame;
        [panel_ setContentSize:size];
        NSRect moved = panel_.frame;  // (grown downward from its top, as a plug-in's size menu expects)
        moved.origin.y = NSMaxY(frame) - moved.size.height;
        [panel_ setFrame:moved display:YES];
    }

    void show(const std::string& title) override {
        panel_.title = [NSString stringWithUTF8String:title.c_str()] ?: @"Plug-in";
        [panel_ orderFront:nil];  // in front, leaving the keyboard with the game
    }

    void hide() override { [panel_ orderOut:nil]; }
    bool visible() const override { return panel_.visible; }
    double scale() const override { return panel_.backingScaleFactor > 0 ? panel_.backingScaleFactor : 1.0; }

    void place(double above_bottom) override {
        NSWindow* game = nil;  // the frontmost window that isn't a plug-in's panel
        for (NSWindow* w in NSApp.orderedWindows)
            if (w != panel_ && ![w isKindOfClass:[NSPanel class]] && w.isVisible) {
                game = w;
                break;
            }
        if (!game) return;
        const NSRect content = [game contentRectForFrameRect:game.frame];
        const NSRect screen = (game.screen ?: NSScreen.mainScreen).visibleFrame;
        NSRect f = panel_.frame;
        f.origin.x = NSMidX(content) - f.size.width / 2;
        f.origin.y = content.origin.y + content.size.height * std::clamp(above_bottom, 0.0, 1.0);
        f.origin.y = std::max(std::min(f.origin.y, NSMaxY(screen) - f.size.height), NSMinY(screen));
        f.origin.x = std::max(std::min(f.origin.x, NSMaxX(screen) - f.size.width), NSMinX(screen));
        [panel_ setFrame:f display:YES];
    }

private:
    SRPlugViewPanel* panel_ = nil;
    SRPlugViewHolder* holder_ = nil;
};

}  // namespace

std::unique_ptr<PluginWindow> PluginWindow::make(int width, int height) { return std::make_unique<MacPluginWindow>(width, height); }
const char* PluginWindow::platformType() { return "NSView"; }

}  // namespace sr
