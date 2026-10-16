#pragma once

// Hosting the effect plug-ins installed on the computer. On macOS that means Audio Units, the format every Mac
// plug-in maker installs alongside its AAX (Pro Tools only) and VST3 versions. Other platforms have none yet.
//
// A plug-in runs in the same process as the game, as it would in a DAW: one that crashes takes SoundRoom with it.

#include <memory>
#include <string>
#include <vector>

namespace sr {

struct PluginDescription {
    std::string id;     // what to load it by: "AU:" and its type, subtype and maker codes, e.g. "AU:aufx:dely:appl"
    std::string name;   // e.g. "AUDelay"
    std::string maker;  // e.g. "Apple"
    std::string category;  // what kind of effect it is, for grouping: "Reverb", "Amps & cabinets"... (a guess; see below)
};

// What kind of effect a plug-in is, from its name, its maker and any tags it carries (plugin_category.cpp).
std::string guessPluginCategory(const std::string& name, const std::string& maker, const std::vector<std::string>& tags);

class PluginInstance {
public:
    // Every effect plug-in installed, by maker and then name (game thread). Quick: nothing is loaded to find them.
    static std::vector<PluginDescription> available();
    // Loads one (game thread, which on macOS must be the main thread). Null, with the reason in `error`, if it can't be.
    static std::unique_ptr<PluginInstance> load(const std::string& id, std::string* error);

    virtual ~PluginInstance() = default;
    virtual const PluginDescription& description() const = 0;
    // Makes it ready for this sample rate, `max_frames` at a time at most (game thread, while it isn't processing).
    virtual bool prepare(double sample_rate, int max_frames, std::string* error) = 0;
    // One channel, in place (audio thread). A plug-in that only works in stereo hears it in both ears, and what it
    // plays back is their average.
    virtual void process(float* io, int n) = 0;
    virtual void setTempo(double bpm) = 0;  // the room's tempo, for plug-ins that keep time (audio thread)
    // The plug-in's own window, floating over the game (game thread). `title` names it.
    virtual bool showEditor(const std::string& title) = 0;
    virtual void hideEditor() = 0;
    virtual bool editorVisible() const = 0;
    virtual int latencySamples() const = 0;  // how late what it plays back is, as it reports
};

}  // namespace sr
