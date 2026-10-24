// A plug-in's window on macOS (an Audio Unit's, plugin_host_mac.mm, or a VST3's, plugin_window_mac.mm): a floating
// panel over the game that leaves the keyboard with the game, so that the computer keyboard keeps playing while a knob
// in it is dragged, unless something in it is being typed into: a box of the system's own, or one a plug-in draws
// itself and types into through the system's text input (as JUCE's do), clicked or opened from a menu. Then it takes
// the keyboard for as long as the typing goes on, and gives it back once it is done.

#pragma once

#import <AppKit/AppKit.h>

@interface SRPluginPanel : NSPanel
// A panel as a plug-in's window is: titled, closable, floating over the game on whichever space it is on, `size` big.
+ (instancetype)panelWithSize:(NSSize)size;
@end
