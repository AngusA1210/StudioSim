// Which format a plug-in is in, by its id, and the plug-ins of every format together.

#include "plugin_formats.h"

#include <cctype>

namespace sr {
namespace {

bool startsWith(const std::string& s, const char* prefix) { return s.rfind(prefix, 0) == 0; }

std::string lower(std::string s) {
    for (char& ch : s) ch = char(std::tolower(static_cast<unsigned char>(ch)));
    return s;
}

// By maker, then name, then format (an Audio Unit before the same plug-in's VST3).
void sortPlugins(std::vector<PluginDescription>& list) {
    std::sort(list.begin(), list.end(), [](const PluginDescription& a, const PluginDescription& b) {
        const std::string am = lower(a.maker), bm = lower(b.maker), an = lower(a.name), bn = lower(b.name);
        if (am != bm) return am < bm;
        return an != bn ? an < bn : a.format < b.format;
    });
}

std::vector<PluginDescription> every(bool instruments) {
    std::vector<PluginDescription> out = vst3Plugins(instruments);
#ifdef __APPLE__
    std::vector<PluginDescription> units = auPlugins(instruments);
    out.insert(out.end(), units.begin(), units.end());
#endif
    sortPlugins(out);
    return out;
}

}  // namespace

std::vector<PluginDescription> PluginInstance::available() { return every(false); }
std::vector<PluginDescription> PluginInstance::availableInstruments() { return every(true); }

std::unique_ptr<PluginInstance> PluginInstance::load(const std::string& id, std::string* error) {
    if (startsWith(id, "VST3:")) return vst3Load(id, error);
#ifdef __APPLE__
    if (startsWith(id, "AU:")) return auLoad(id, error);
#else
    if (startsWith(id, "AU:")) {
        if (error) *error = "it is an Audio Unit, which only a Mac has";
        return nullptr;
    }
#endif
    if (error) *error = "\"" + id + "\" isn't a plug-in";
    return nullptr;
}

std::string presetExtension(const std::string& plugin_id) { return startsWith(plugin_id, "VST3:") ? "vstpreset" : "aupreset"; }

bool writePluginPreset(const std::string& path, const std::string& name, const std::vector<uint8_t>& state, std::string* error) {
    if (lower(path).size() >= 10 && lower(path).compare(lower(path).size() - 10, 10, ".vstpreset") == 0)
        return vst3WritePreset(path, name, state, error);
#ifdef __APPLE__
    return auWritePreset(path, name, state, error);
#else
    if (error) *error = "only a Mac has Audio Unit presets";
    return false;
#endif
}

bool readPluginPreset(const std::string& path, PluginPresetFile* out, std::string* error) {
    if (lower(path).size() >= 10 && lower(path).compare(lower(path).size() - 10, 10, ".vstpreset") == 0)
        return vst3ReadPreset(path, out, error);
#ifdef __APPLE__
    return auReadPreset(path, out, error);
#else
    if (error) *error = "only a Mac has Audio Unit presets";
    return false;
#endif
}

}  // namespace sr
