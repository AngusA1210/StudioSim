#pragma once

// Hosting the plug-ins installed on the computer, in the formats their makers install them in besides AAX (Pro Tools'
// own): VST3 everywhere (Steinberg's VST 3 SDK, MIT-licensed), and on macOS Audio Units as well. A plug-in is known by
// its id, which says its format: "AU:" and its codes, or "VST3:" and its class's id, which is the same on macOS and
// Windows, so a room whose plug-ins are VST3s opens on either with them (their settings too, as the plug-in saves them).
//
// A plug-in runs in the same process as the game, as it would in a DAW: one that crashes takes SoundRoom with it.

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace sr {

struct PluginDescription {
    std::string id;     // what to load it by: "AU:" and its type, subtype and maker codes, e.g. "AU:aufx:dely:appl";
                        // or "VST3:" and its class id in hexadecimal
    std::string format = "AU";  // "AU" or "VST3"
    std::string name;   // e.g. "AUDelay"
    std::string maker;  // e.g. "Apple"
    std::string category;  // what kind of effect it is, for grouping: "Reverb", "Amps & cabinets"... (a guess; see below)
    bool instrument = false;  // an instrument (it makes its own sound from MIDI) rather than an effect
};

// One of a plug-in's controls, as it lists them: what automation can move.
struct PluginParameter {
    uint32_t id = 0;
    std::string name;
    std::string unit;  // "dB", "Hz", "%"... ("" for none it names)
    float min = 0.0f, max = 1.0f, initial = 0.0f;
};

// What kind of effect a plug-in is, from its name, its maker and any tags it carries (plugin_category.cpp); and the
// same for an instrument plug-in ("Synths", "Pianos & keys", "Drums & percussion", "Samplers"...).
std::string guessPluginCategory(const std::string& name, const std::string& maker, const std::vector<std::string>& tags);
std::string guessInstrumentCategory(const std::string& name, const std::string& maker, const std::vector<std::string>& tags);
std::string vst3Category(const std::vector<std::string>& subcategories, bool instrument);  // "" if it doesn't say

// Where VST3 plug-ins are looked for: the system's folders (none given), or only these (the checks' own test plug-in).
void setVst3SearchPaths(const std::vector<std::string>& paths);
// Each VST3 module found at the last look that wouldn't load, and why ("<its path>: <the reason>").
std::vector<std::string> vst3ScanProblems();

class PluginInstance {
public:
    // Every effect plug-in installed, by maker and then name (game thread). Quick: nothing is loaded to find them (a
    // VST3 that doesn't describe itself in its bundle is loaded once to see what it is, and remembered).
    static std::vector<PluginDescription> available();
    static std::vector<PluginDescription> availableInstruments();  // likewise the instruments: synthesizers, samplers...
    // Loads one (game thread, which on macOS must be the main thread). Null, with the reason in `error`, if it can't be.
    static std::unique_ptr<PluginInstance> load(const std::string& id, std::string* error);

    virtual ~PluginInstance() = default;
    virtual const PluginDescription& description() const = 0;
    // Makes it ready for this sample rate, `max_frames` at a time at most (game thread, while it isn't processing):
    // in one channel if it will (for a track's insert or a pedal), or with `stereo` in two if it will (a bus's insert).
    virtual bool prepare(double sample_rate, int max_frames, std::string* error, bool stereo = false) = 0;
    // One channel, in place (audio thread). A plug-in that only works in stereo hears it in both ears, and what it
    // plays back is their average.
    virtual void process(float* io, int n) = 0;
    // Two channels, in place (audio thread). One prepared in one channel hears the two together, and plays it in both.
    virtual void processStereo(float* left, float* right, int n) {
        for (int i = 0; i < n; ++i) left[i] = 0.5f * (left[i] + right[i]);
        process(left, n);
        std::copy(left, left + n, right);
    }
    // An instrument (audio thread): a MIDI message to act on `offset` samples into the next render, and rendering,
    // added into `out` as one channel (the average of a stereo instrument's two).
    virtual bool isInstrument() const = 0;
    virtual void midi(uint8_t status, uint8_t data1, uint8_t data2, int offset) = 0;
    virtual void render(float* out, int n) = 0;
    virtual void setTempo(double bpm) = 0;  // the room's tempo, for plug-ins that keep time (audio thread)
    // The plug-in's own window, floating over the game (game thread). `title` names it.
    virtual bool showEditor(const std::string& title) = 0;
    virtual void hideEditor() = 0;
    // Moves its window to the middle of the game's window, its bottom `above_bottom` of the way up it (0 to 1), and
    // on the screen.
    virtual void placeEditor(double /*above_bottom*/) {}
    virtual bool editorVisible() const = 0;
    virtual int latencySamples() const = 0;  // how late what it plays back is, as it reports
    // Its settings, as the plug-in itself saves them (an Audio Unit's class info, as a binary property list), and
    // putting them back: for copying a plug-in with its settings, and for saving them (game thread).
    virtual std::vector<uint8_t> saveState() const = 0;
    virtual bool loadState(const std::vector<uint8_t>& state) = 0;
    // Its controls that can be set (game thread), each control's value now (any thread), and setting one (any thread:
    // the audio thread, as automation plays, between blocks).
    virtual std::vector<PluginParameter> parameters() const { return {}; }
    virtual float parameter(uint32_t /*id*/) const { return 0.0f; }
    virtual void setParameter(uint32_t /*id*/, float /*value*/) {}
    // Tells its window a control was set from outside it, so that it shows it (game thread).
    virtual void notifyParameter(uint32_t /*id*/) {}
    // A value of a control as the plug-in writes it ("-6.0 dB", "Hall"), or "" if it doesn't say (game thread).
    virtual std::string parameterText(uint32_t /*id*/, float /*value*/) const { return ""; }
    // The presets the plug-in comes with, by name, and switching to one (game thread).
    virtual std::vector<std::string> factoryPresets() const = 0;
    virtual bool loadFactoryPreset(int index) = 0;
};

// A preset file of the kind every host of the format shares: an Audio Unit's .aupreset (kept in
// ~/Library/Audio/Presets/Maker/Plug-in), a VST3's .vstpreset (in the same folders on macOS, Documents/VST3 Presets on
// Windows): a plug-in's settings under a name. Writing one gives the settings that name (and makes the folders it goes
// in); reading one gives the plug-in it is for, its name and the settings, ready for loadState. The file's extension
// says which kind it is.
struct PluginPresetFile {
    std::string plugin_id, name;
    std::vector<uint8_t> state;
};
bool writePluginPreset(const std::string& path, const std::string& name, const std::vector<uint8_t>& state, std::string* error);
bool readPluginPreset(const std::string& path, PluginPresetFile* out, std::string* error);
std::string presetExtension(const std::string& plugin_id);  // "aupreset" or "vstpreset"

}  // namespace sr
