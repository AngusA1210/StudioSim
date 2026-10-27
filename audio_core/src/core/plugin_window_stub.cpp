// Plug-in windows where Studiolator has none to offer yet (Linux): a plug-in is heard, and its controls automated, but its
// own window can't be shown.

#include "plugin_window.h"

namespace sr {

std::unique_ptr<PluginWindow> PluginWindow::make(int, int) { return nullptr; }
const char* PluginWindow::platformType() { return ""; }

}  // namespace sr
