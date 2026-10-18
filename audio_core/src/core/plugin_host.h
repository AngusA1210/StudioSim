#pragma once

// Hosting the effect plug-ins installed on the computer. On macOS that means Audio Units, the format every Mac
// plug-in maker installs alongside its AAX (Pro Tools only) and VST3 versions. Other platforms have none yet.
//
// A plug-in runs in the same process as the game, as it would in a DAW: one that crashes takes SoundRoom with it.

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace sr {

struct PluginDescription {
    std::string id;     // what to load it by: "AU:" and its type, subtype and maker codes, e.g. "AU:aufx:dely:appl"
    std::string name;   // e.g. "AUDelay"
    std::string maker;  // e.g. "Apple"
    std::string category;  // what kind of effect it is, for grouping: "Reverb", "Amps & cabinets"... (a guess; see below)
    bool instrument = false;  // an instrument (it makes its own sound from MIDI) rather than an effect
};

// What kind of effect a plug-in is, from its name, its maker and any tags it carries (plugin_category.cpp); and the
// same for an instrument plug-in ("Synths", "Pianos & keys", "Drums & percussion", "Samplers"...).
std::string guessPluginCategory(const std::string& name, const std::string& maker, const std::vector<std::string>& tags);
std::string guessInstrumentCategory(const std::string& name, const std::string& maker, const std::vector<std::string>& tags);

class PluginInstance {
public:
    // Every effect plug-in installed, by maker and then name (game thread). Quick: nothing is loaded to find them.
    static std::vector<PluginDescription> available();
    static std::vector<PluginDescription> availableInstruments();  // likewise the instruments: synthesizers, samplers...
    // Loads one (game thread, which on macOS must be the main thread). Null, with the reason in `error`, if it can't be.
    static std::unique_ptr<PluginInstance> load(const std::string& id, std::string* error);

    virtual ~PluginInstance() = default;
    virtual const PluginDescription& description() const = 0;
    // Makes it ready for this sample rate, `max_frames` at a time at most (game thread, while it isn't processing).
    virtual bool prepare(double sample_rate, int max_frames, std::string* error) = 0;
    // One channel, in place (audio thread). A plug-in that only works in stereo hears it in both ears, and what it
    // plays back is their average.
    virtual void process(float* io, int n) = 0;
    // An instrument (audio thread): a MIDI message to act on `offset` samples into the next render, and rendering,
    // added into `out` as one channel (the average of a stereo instrument's two).
    virtual bool isInstrument() const = 0;
    virtual void midi(uint8_t status, uint8_t data1, uint8_t data2, int offset) = 0;
    virtual void render(float* out, int n) = 0;
    virtual void setTempo(double bpm) = 0;  // the room's tempo, for plug-ins that keep time (audio thread)
    // The plug-in's own window, floating over the game (game thread). `title` names it.
    virtual bool showEditor(const std::string& title) = 0;
    virtual void hideEditor() = 0;
    virtual bool editorVisible() const = 0;
    virtual int latencySamples() const = 0;  // how late what it plays back is, as it reports
    // Its settings, as the plug-in itself saves them (an Audio Unit's class info, as a binary property list), and
    // putting them back: for copying a plug-in with its settings, and for saving them (game thread).
    virtual std::vector<uint8_t> saveState() const = 0;
    virtual bool loadState(const std::vector<uint8_t>& state) = 0;
    // The presets the plug-in comes with, by name, and switching to one (game thread).
    virtual std::vector<std::string> factoryPresets() const = 0;
    virtual bool loadFactoryPreset(int index) = 0;
};

// A preset file of the kind every Audio Unit host shares (.aupreset, kept in ~/Library/Audio/Presets/Maker/Plug-in):
// a plug-in's settings under a name. Writing one gives the settings that name (and makes the folders it goes in);
// reading one gives the plug-in it is for, its name and the settings, ready for loadState.
struct PluginPresetFile {
    std::string plugin_id, name;
    std::vector<uint8_t> state;
};
bool writePluginPreset(const std::string& path, const std::string& name, const std::vector<uint8_t>& state, std::string* error);
bool readPluginPreset(const std::string& path, PluginPresetFile* out, std::string* error);

}  // namespace sr
