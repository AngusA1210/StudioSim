// What kind of effect a plug-in is, for grouping the plug-in browser by type. Most plug-ins don't say (only Apple's
// carry the tags meant for this), so it is mostly worked out from the name: words such as "reverb", "compressor" or
// "amp", and the names of a few well-known units. A guess, then; grouping by maker is always exact.

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

#include "plugin_host.h"

namespace sr {
namespace {

std::string lower(std::string s) {
    for (char& c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// The name's words, split at anything that isn't a letter or a digit.
std::vector<std::string> wordsOf(const std::string& s) {
    std::vector<std::string> words;
    std::string word;
    for (char c : s) {
        if (std::isalnum(static_cast<unsigned char>(c))) {
            word += c;
        } else if (!word.empty()) {
            words.push_back(word);
            word.clear();
        }
    }
    if (!word.empty()) words.push_back(word);
    return words;
}

struct Rule {
    const char* category;
    std::vector<std::string> within;  // found anywhere in the name
    std::vector<std::string> words;   // found as a whole word
};

// In order: the first that fits wins, so "Tape Echo" is a delay and "Reverb Amp" an amp.
const std::vector<Rule>& rules() {
    static const std::vector<Rule> kRules = {
        {"Restoration", {"rx 1", "de-noise", "denoise", "de-click", "de-clip", "de-crackle", "de-hum", "de-reverb", "de-plosive",
                         "breath control", "isolat", "soundsoap", "repair", "rebalance", "spectral"}, {}},
        {"Amps & cabinets", {"tone3000", "neural", "archetype", "amplitube", "guitar rig", "helix", "cabinet"},
         {"amp", "amps", "amplifier", "cab", "nam"}},
        {"Channel strips", {"channel strip"}, {}},
        {"EQ", {"equaliz", "equalis", "pultec", "pro-q", "sie-q", "shelf", "graphiceq", "nbandeq", "parametriceq"}, {"eq", "nova"}},
        {"Dynamics", {"compressor", "limiter", "expander", "de-ess", "deess", "dynamic", "pro-c", "pro-l", "pro-mb", "pro-ds", "1176",
                      "la-2", "fairchild", "distressor", "dbx", "transient", "multiband", "dynassist"},
         {"comp", "gate", "punch"}},
        {"Reverb", {"verb", "plate", "lexicon", "supermassive", "pro-r", "spaceblender", "sound city", "spring"}, {"room", "hall", "224"}},
        {"Delay", {"delay", "echo", "primaltap", "timeless", "crystallizer"}, {"tap"}},
        {"Modulation", {"chorus", "flang", "phase", "tremol", "vibrato", "rotary", "leslie", "panman", "modulat", "ensemble"}, {}},
        {"Saturation & distortion", {"saturat", "saturn", "decapitator", "radiator", "distort", "drive", "fuzz", "tape", "ampex",
                                     "studer", "devil-loc", "tube", "crush", "analog machine"},
         {"warm", "atr"}},
        {"Filter", {"filter", "lowpass", "hipass", "highpass", "bandpass", "wah"}, {}},
        {"Pitch & vocal", {"tune", "pitch", "shift", "alterboy", "harmony", "melodyne", "vocod", "throat", "choir", "articulator",
                           "aspire", "mutator", "auto-key", "metamorph", "vocal", "voice"},
         {"duo"}},
        {"Mastering", {"ozone", "mastering"}, {}},
        {"Spatial", {"dearvr", "ambi", "soundfield", "binaural", "panner", "spatial", "imager", "stereo"}, {}},
        {"Utility & metering", {"insight", "meter", "soundid", "netsend", "roundtrip", "utility", "analy"}, {"gain", "trim"}},
    };
    return kRules;
}

}  // namespace

std::string guessPluginCategory(const std::string& name, const std::string& maker, const std::vector<std::string>& tags) {
    const std::string n = lower(name);
    const std::vector<std::string> words = wordsOf(n);
    for (const Rule& rule : rules()) {
        for (const auto& part : rule.within)
            if (n.find(part) != std::string::npos) return rule.category;
        for (const auto& word : rule.words)
            if (std::find(words.begin(), words.end(), word) != words.end()) return rule.category;
    }
    // What the plug-in says about itself, where it does.
    static const std::pair<const char*, const char*> kTags[] = {
        {"Equalizer", "EQ"}, {"Dynamics Processor", "Dynamics"}, {"Dynamics", "Dynamics"}, {"Reverb", "Reverb"},
        {"Delay", "Delay"}, {"Distortion", "Saturation & distortion"}, {"Filter", "Filter"}, {"Pitch", "Pitch & vocal"},
        {"Modulation", "Modulation"}, {"Amp Simulator", "Amps & cabinets"},
    };
    for (const auto& [tag, category] : kTags)
        if (std::find(tags.begin(), tags.end(), tag) != tags.end()) return category;
    // Makers known for one kind of thing.
    const std::string m = lower(maker);
    if (m.find("antares") != std::string::npos || m.find("celemony") != std::string::npos) return "Pitch & vocal";
    if (m.find("dear reality") != std::string::npos) return "Spatial";
    if (m.find("izotope") != std::string::npos) return "Restoration";
    return "Other";
}

// A VST3 says what kind it is (its subcategories, "Fx|Reverb" or "Instrument|Drum"), more exactly than its name does:
// what its kind is, where it says one ("" where it says only "Fx", or "Tools").
std::string vst3Category(const std::vector<std::string>& subcategories, bool instrument) {
    static const std::pair<const char*, const char*> kEffects[] = {
        {"EQ", "EQ"}, {"Dynamics", "Dynamics"}, {"Reverb", "Reverb"}, {"Delay", "Delay"}, {"Distortion", "Saturation & distortion"},
        {"Filter", "Filter"}, {"Pitch Shift", "Pitch & vocal"}, {"Modulation", "Modulation"}, {"Spatial", "Spatial"},
        {"Surround", "Spatial"}, {"Analyzer", "Utility & metering"}, {"Mastering", "Mastering"}, {"Restoration", "Restoration"},
    };
    static const std::pair<const char*, const char*> kInstruments[] = {
        {"Drum", "Drums & percussion"}, {"Piano", "Pianos & keys"}, {"Sampler", "Samplers"}, {"Synth", "Synths"},
        {"Orchestral", "Orchestral & acoustic"}, {"External", "Other"},
    };
    for (const auto& [tag, category] : instrument ? std::vector<std::pair<const char*, const char*>>(std::begin(kInstruments), std::end(kInstruments))
                                                  : std::vector<std::pair<const char*, const char*>>(std::begin(kEffects), std::end(kEffects)))
        if (std::find(subcategories.begin(), subcategories.end(), tag) != subcategories.end()) return category;
    return "";
}

std::string guessInstrumentCategory(const std::string& name, const std::string& maker, const std::vector<std::string>& tags) {
    static const std::vector<Rule> kInstrumentRules = {
        {"Drums & percussion", {"drum", "808", "909", "percuss", "battery", "groove agent", "ezdrummer", "bfd", "beatmaker"},
         {"kit", "kits", "beat", "beats"}},
        {"Pianos & keys", {"piano", "rhodes", "wurli", "organ", "clav", "keyscape", "e-piano", "epiano", "mellotron", "celest"},
         {"keys", "grand", "b3"}},
        {"Samplers", {"sampler", "kontakt", "soundfont", "sfz", "decent", "dls", "rompler"}, {"sample", "samples"}},
        {"Orchestral & acoustic", {"orchestr", "symphon", "string", "brass", "woodwind", "spitfire", "choir", "harp", "bbc"}, {"labs"}},
        {"Synths", {"synth", "diva", "serum", "vital", "massive", "omnisphere", "pigments", "repro", "zebra", "hive", "sylenth",
                    "phase plant", "moog", "prophet", "juno", "jupiter", "analog", "modular", "wavetable", "oscillat"},
         {"fm", "mono", "poly"}},
    };
    const std::string n = lower(name);
    const std::vector<std::string> words = wordsOf(n);
    for (const Rule& rule : kInstrumentRules) {
        for (const auto& part : rule.within)
            if (n.find(part) != std::string::npos) return rule.category;
        for (const auto& word : rule.words)
            if (std::find(words.begin(), words.end(), word) != words.end()) return rule.category;
    }
    static const std::pair<const char*, const char*> kTags[] = {
        {"Synthesizer", "Synths"}, {"Sampler", "Samplers"}, {"Drums", "Drums & percussion"}, {"Piano", "Pianos & keys"},
    };
    for (const auto& [tag, category] : kTags)
        if (std::find(tags.begin(), tags.end(), tag) != tags.end()) return category;
    const std::string m = lower(maker);
    if (m.find("native instruments") != std::string::npos) return "Samplers";
    if (m.find("spitfire") != std::string::npos) return "Orchestral & acoustic";
    return "Other";
}

}  // namespace sr
