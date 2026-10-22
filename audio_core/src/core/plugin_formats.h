#pragma once

// The plug-in formats behind PluginInstance, each in a file of its own; plugin_host.cpp picks one by a plug-in's id.
// Audio Units on macOS (plugin_host_mac.mm), VST3 everywhere (plugin_host_vst3.cpp).

#include "plugin_host.h"

namespace sr {

#ifdef __APPLE__
std::vector<PluginDescription> auPlugins(bool instruments);
std::unique_ptr<PluginInstance> auLoad(const std::string& id, std::string* error);
bool auWritePreset(const std::string& path, const std::string& name, const std::vector<uint8_t>& state, std::string* error);
bool auReadPreset(const std::string& path, PluginPresetFile* out, std::string* error);
#endif

std::vector<PluginDescription> vst3Plugins(bool instruments);
std::unique_ptr<PluginInstance> vst3Load(const std::string& id, std::string* error);
bool vst3WritePreset(const std::string& path, const std::string& name, const std::vector<uint8_t>& state, std::string* error);
bool vst3ReadPreset(const std::string& path, PluginPresetFile* out, std::string* error);

}  // namespace sr
