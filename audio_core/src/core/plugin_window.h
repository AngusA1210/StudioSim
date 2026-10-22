#pragma once

// A window for a plug-in's own view (a VST3's editor), floating over the game as a DAW's plug-in windows float over
// it: each platform's own (plugin_window_mac.mm, plugin_window_win.cpp). The plug-in draws itself into the window's
// native view (an NSView on macOS, an HWND on Windows) and asks for the size it wants. Game thread only.

#include <functional>
#include <memory>
#include <string>

namespace sr {

class PluginWindow {
public:
    // A window `width` by `height` (points), hidden until shown; null where windows can't be made.
    static std::unique_ptr<PluginWindow> make(int width, int height);
    // What kind of native view a plug-in should attach to, as VST3 names them ("NSView", "HWND"), or "".
    static const char* platformType();

    virtual ~PluginWindow() = default;
    virtual void* nativeView() = 0;
    virtual void setContentSize(int width, int height) = 0;  // as the plug-in asks
    virtual void show(const std::string& title) = 0;         // in front, leaving the keyboard with the game
    virtual void hide() = 0;
    virtual bool visible() const = 0;
    // To the middle of the game's window, its bottom `above_bottom` of the way up it (0 to 1), kept on the screen.
    virtual void place(double above_bottom) = 0;
    // The window's scale against points (a Retina screen's 2), for plug-ins that draw in pixels.
    virtual double scale() const { return 1.0; }
};

}  // namespace sr
