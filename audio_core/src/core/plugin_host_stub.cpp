// Plug-in hosting on platforms that have none yet: there is nothing to list or load.

#include "plugin_host.h"

namespace sr {

std::vector<PluginDescription> PluginInstance::available() { return {}; }

std::unique_ptr<PluginInstance> PluginInstance::load(const std::string&, std::string* error) {
    if (error) *error = "plug-ins aren't supported on this platform yet";
    return nullptr;
}

bool writePluginPreset(const std::string&, const std::string&, const std::vector<uint8_t>&, std::string* error) {
    if (error) *error = "plug-ins aren't supported on this platform yet";
    return false;
}

bool readPluginPreset(const std::string&, PluginPresetFile*, std::string* error) {
    if (error) *error = "plug-ins aren't supported on this platform yet";
    return false;
}

}  // namespace sr
