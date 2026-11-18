#include "studiosim_audio.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {
namespace {

sr::Vec3 vec(const Vector3& v) { return sr::Vec3{float(v.x), float(v.y), float(v.z)}; }
String str(const std::string& s) { return String::utf8(s.c_str()); }
std::string str(const String& s) { return std::string(s.utf8().get_data()); }
sr::PluginPlace placeOf(const String& place) {
    return place == "insert" ? sr::PluginPlace::Insert : place == "instrument" ? sr::PluginPlace::Instrument : sr::PluginPlace::Pedal;
}
std::vector<uint8_t> bytes(const PackedByteArray& b) { return std::vector<uint8_t>(b.ptr(), b.ptr() + b.size()); }
PackedByteArray bytes(const std::vector<uint8_t>& v) {
    PackedByteArray out;
    out.resize(int64_t(v.size()));
    if (!v.empty()) std::copy(v.begin(), v.end(), out.ptrw());
    return out;
}

const char* const kPedalNames[sr::kPedalKinds] = {"tuner", "gate", "compressor", "overdrive", "fuzz", "envelope_filter",
                                                  "chorus", "phaser", "tremolo", "delay", "reverb", "looper", "plugin"};

Array deviceList(const std::vector<sr::AudioDeviceInfo>& devices) {
    Array out;
    for (const auto& d : devices) {
        Dictionary entry;
        entry["name"] = str(d.name);
        entry["is_default"] = d.is_default;
        entry["channels"] = d.channels;
        out.push_back(entry);
    }
    return out;
}

}  // namespace

StudioSimAudio::StudioSimAudio() = default;

StudioSimAudio::~StudioSimAudio() { stop(); }

void StudioSimAudio::_notification(int what) {
    if (what == NOTIFICATION_PREDELETE) stop();
}

// What each VST3 module holds, kept between sessions (see setVst3ScanRecord): read before plug-ins are first looked for.
static void keepScanRecord() {
    static bool kept = false;
    if (kept) return;
    kept = true;
    sr::setVst3ScanRecord(str(OS::get_singleton()->get_user_data_dir() + "/vst3_scan.txt"));
}

bool StudioSimAudio::ensureEngine() {
    keepScanRecord();
    if (engine_) return true;
    auto engine = std::make_unique<sr::AudioEngine>();
    std::string err;
    if (!engine->init(&err)) {
        error_ = str(err);
        UtilityFunctions::push_error("StudioSimAudio: ", error_);
        return false;
    }
    engine_ = std::move(engine);
    return true;
}

// ── Playback engine and I/O ────────────────────────────────────────────────────────────────────────────────
bool StudioSimAudio::start(bool silent) {
    Dictionary config;
    config["silent"] = silent;
    return open_device(config);
}

bool StudioSimAudio::open_device(const Dictionary& config) {
    if (!ensureEngine()) return false;
    sr::DeviceConfig c;
    c.mode = bool(config.get("silent", false)) ? sr::DeviceMode::Null : sr::DeviceMode::Hardware;
    c.output_device = str(String(config.get("output_device", "")));
    c.input_enabled = bool(config.get("input_enabled", false));
    c.input_device = str(String(config.get("input_device", "")));
    c.buffer_size = int(config.get("buffer_size", 128));
    c.output_left = int(config.get("output_left", 0));
    c.output_right = int(config.get("output_right", 1));
    c.sample_rate = int(config.get("sample_rate", 0));
    std::string err;
    if (engine_->openDevice(c, &err)) {
        error_ = String();
        return true;
    }
    error_ = str(err);
    return false;
}

Dictionary StudioSimAudio::get_device_config() const {
    Dictionary d;
    if (!engine_) return d;
    const sr::DeviceConfig& c = engine_->deviceConfig();
    d["silent"] = c.mode == sr::DeviceMode::Null;
    d["output_device"] = str(c.output_device);
    d["input_enabled"] = c.input_enabled;
    d["input_device"] = str(c.input_device);
    d["buffer_size"] = c.buffer_size;
    d["output_left"] = c.output_left;
    d["output_right"] = c.output_right;
    d["sample_rate"] = c.sample_rate;
    return d;
}

Array StudioSimAudio::get_output_devices() const { return deviceList(sr::AudioEngine::outputDevices()); }
Array StudioSimAudio::get_input_devices() const { return deviceList(sr::AudioEngine::inputDevices()); }

void StudioSimAudio::set_output_channels(int left, int right) { if (engine_) engine_->setOutputChannels(left, right); }

bool StudioSimAudio::set_live_input(bool enabled) {
    if (!engine_) return false;
    std::string err;
    if (engine_->setLiveInput(enabled, &err)) return true;
    error_ = str(err);
    return false;
}

void StudioSimAudio::stop() { engine_.reset(); }

// Quitting: the engine stopped (the device closed, each plug-in let go as a DAW lets it go), then the process ended
// there and then, without the static destructors and exit handlers that plug-ins' own code leaves behind. Some of
// those crash a process as it ends (a plug-in's timer thread still running as its library is torn down, a module's
// bundleExit), and macOS then says it "quit unexpectedly", though nothing was lost: what had to be saved was.
void StudioSimAudio::quit_process(int code) {
    stop();
    std::fflush(nullptr);
    std::_Exit(code);
}

bool StudioSimAudio::is_running() const { return engine_ && engine_->stats().device_running; }

// ── The room ───────────────────────────────────────────────────────────────────────────────────────────────
int StudioSimAudio::add_source(const String& kind, const Vector3& position, float gain, float reverb_send) {
    if (!ensureEngine()) return -1;
    sr::InstrumentKind k;
    if (kind == "drums") k = sr::InstrumentKind::Drums;
    else if (kind == "bass") k = sr::InstrumentKind::Bass;
    else if (kind == "pad") k = sr::InstrumentKind::Pad;
    else if (kind == "bells") k = sr::InstrumentKind::Bells;
    else if (kind == "keys") k = sr::InstrumentKind::Keys;
    else if (kind == "garage_drums") k = sr::InstrumentKind::GarageDrums;
    else if (kind == "studio_drums") k = sr::InstrumentKind::StudioDrums;
    else if (kind == "plugin_synth") k = sr::InstrumentKind::PluginSynth;
    else if (kind == "live") k = sr::InstrumentKind::Live;
    else if (kind == "guitar_combo") k = sr::InstrumentKind::GuitarCombo;
    else if (kind == "guitar_stack") k = sr::InstrumentKind::GuitarStack;
    else if (kind == "bass_combo") k = sr::InstrumentKind::BassCombo;
    else if (kind == "bass_stack") k = sr::InstrumentKind::BassStack;
    else if (kind == "bus") k = sr::InstrumentKind::Bus;
    else if (kind == "mic") k = sr::InstrumentKind::Mic;
    else if (kind == "stereo_mic") k = sr::InstrumentKind::StereoMic;
    else {
        UtilityFunctions::push_error("StudioSimAudio: unknown instrument kind ", kind);
        return -1;
    }
    return engine_->addSource(k, vec(position), gain, reverb_send);
}

bool StudioSimAudio::remove_source(int id) { return engine_ && engine_->removeSource(id); }
int StudioSimAudio::get_source_count() const { return engine_ ? engine_->sourceCount() : 0; }
int StudioSimAudio::get_max_sources() const { return sr::AudioEngine::kMaxSources; }

void StudioSimAudio::set_source_position(int id, const Vector3& p) { if (engine_) engine_->setSourcePosition(id, vec(p)); }

bool StudioSimAudio::is_source_blocked(int id) const { return engine_ && engine_->sourceBlocked(id); }
void StudioSimAudio::set_source_gain(int id, float gain) { if (engine_) engine_->setSourceGain(id, gain); }

void StudioSimAudio::set_room(const Vector3& size, const Array& walls, const Dictionary& surfaces) {
    if (!ensureEngine()) return;
    const auto material = [](const Variant& id, sr::Material otherwise) {
        return id.get_type() == Variant::STRING ? sr::materialFromId(str(String(id)), otherwise) : otherwise;
    };
    std::vector<sr::Wall> list;
    for (int64_t i = 0; i < walls.size(); ++i) {
        const Dictionary wall = walls[i];
        const Vector2 a = wall.get("a", Vector2()), b = wall.get("b", Vector2());
        list.push_back({float(a.x), float(a.y), float(b.x), float(b.y), float(wall.get("thickness", 0.3)), float(wall.get("height", 3.0)),
                        material(wall.get("material", Variant()), sr::Material::Drywall)});
    }
    sr::RoomSurfaces room;
    room.floor = material(surfaces.get("floor", Variant()), room.floor);
    room.ceiling = material(surfaces.get("ceiling", Variant()), room.ceiling);
    room.north = material(surfaces.get("north", Variant()), room.north);
    room.south = material(surfaces.get("south", Variant()), room.south);
    room.east = material(surfaces.get("east", Variant()), room.east);
    room.west = material(surfaces.get("west", Variant()), room.west);
    engine_->setRoom(float(size.x), float(size.y), float(size.z), list, room);
}

PackedFloat32Array StudioSimAudio::get_room_decay_bands() const {
    PackedFloat32Array out;
    if (engine_)
        for (float seconds : engine_->roomDecay()) out.push_back(seconds);
    return out;
}

void StudioSimAudio::set_early_reflections(bool on) { if (engine_) engine_->setEarlyReflections(on); }

bool StudioSimAudio::is_room_settled() { return engine_ && engine_->roomSettled(); }
float StudioSimAudio::get_room_decay() const { return engine_ ? engine_->roomDecaySeconds() : 0.0f; }

void StudioSimAudio::set_source_muted(int id, bool muted) { if (engine_) engine_->setSourceMuted(id, muted); }
void StudioSimAudio::set_source_solo_muted(int id, bool silenced) { if (engine_) engine_->setSourceSoloMuted(id, silenced); }

Array StudioSimAudio::get_mic_models() const {
    Array out;
    for (const sr::MicModel& m : sr::micModels()) {
        Dictionary d;
        d["id"] = String(m.id.c_str());
        d["name"] = String::utf8(m.name.c_str());
        d["about"] = String::utf8(m.about.c_str());
        d["sensitivity_db"] = m.sensitivity_db;
        d["self_noise_db"] = m.self_noise_db;
        d["noise_db"] = sr::micNoiseSpl(m);
        Array patterns;
        for (const auto& [pattern, polar] : m.patterns) {
            Dictionary p;
            p["name"] = String(sr::micPatternName(pattern));
            Array pressure, gradient;
            for (int b = 0; b < 3; ++b) {
                pressure.push_back(polar.pressure[size_t(b)]);
                gradient.push_back(polar.gradient[size_t(b)]);
            }
            p["pressure"] = pressure;
            p["gradient"] = gradient;
            patterns.push_back(p);
        }
        d["patterns"] = patterns;
        out.push_back(d);
    }
    return out;
}

PackedFloat32Array StudioSimAudio::get_mic_response(const String& model, const PackedFloat32Array& frequencies) const {
    PackedFloat32Array out;
    const int index = sr::micModelIndex(str(model));
    if (index < 0) return out;
    for (int i = 0; i < frequencies.size(); ++i) out.push_back(sr::micResponseDb(sr::micModels()[size_t(index)], frequencies[i]));
    return out;
}

void StudioSimAudio::set_mic_model(int id, const String& model, const String& pattern, int capsule) {
    if (!engine_) return;
    sr::MicPattern p = sr::MicPattern::Omni;
    for (sr::MicPattern each : {sr::MicPattern::Omni, sr::MicPattern::Cardioid, sr::MicPattern::Supercardioid, sr::MicPattern::Figure8})
        if (pattern == sr::micPatternName(each)) p = each;
    engine_->setMicModel(id, str(model), p, capsule);
}

void StudioSimAudio::set_mic_aim(int id, const Vector3& aim, int capsule) { if (engine_) engine_->setMicAim(id, vec(aim), capsule); }
void StudioSimAudio::set_mic_capsule(int id, int capsule, const Vector3& position) { if (engine_) engine_->setMicCapsule(id, capsule, vec(position)); }
void StudioSimAudio::set_mic_mid_side(int id, bool mid_side, float width) { if (engine_) engine_->setMicMidSide(id, mid_side, width); }
float StudioSimAudio::get_mic_noise(const String& model) const {
    const int index = sr::micModelIndex(str(model));
    return index < 0 ? 0.0f : sr::micNoiseSpl(sr::micModels()[size_t(index)]);
}
void StudioSimAudio::set_source_pan(int id, float pan) { if (engine_) engine_->setSourcePan(id, pan); }
void StudioSimAudio::set_bus_mono(int id, bool mono) { if (engine_) engine_->setBusMono(id, mono); }
void StudioSimAudio::set_bus_pans(int id, float left, float right) { if (engine_) engine_->setBusPans(id, left, right); }
void StudioSimAudio::set_floor_reflection(float amount) { if (engine_) engine_->setFloorReflection(amount); }
void StudioSimAudio::set_source_radiator(int id, const PackedVector3Array& cones, const Vector3& facing, float inches, bool open_back,
                                         const Vector3& back, float width, float coverage_deg, float crossover_hz) {
    if (!engine_) return;
    sr::Radiator r;
    r.cones = int(std::min<int64_t>(cones.size(), sr::kMaxCones));
    for (int i = 0; i < r.cones; ++i) r.cone[size_t(i)] = vec(cones[i]);
    const Vector3 n = facing.length() > 1e-6f ? facing.normalized() : Vector3(0, 0, 1);
    r.facing = vec(n);
    r.inches = inches;
    r.open_back = open_back;
    r.back = vec(back);
    r.width = width;
    r.coverage = coverage_deg * 3.14159265f / 180.0f;
    r.crossover_hz = crossover_hz;
    engine_->setSourceRadiator(id, r);
}
void StudioSimAudio::set_source_parts(int id, const PackedVector3Array& centres, const PackedVector3Array& facings,
                                      const PackedFloat32Array& radii, const PackedByteArray& plates, const PackedInt32Array& drums,
                                      const PackedFloat32Array& insides) {
    if (!engine_) return;
    std::vector<sr::SoundingPart> parts(size_t(centres.size()));
    for (int64_t i = 0; i < centres.size(); ++i) {
        sr::SoundingPart& p = parts[size_t(i)];
        p.centre = vec(centres[i]);
        const Vector3 n = i < facings.size() && facings[i].length() > 1e-6f ? facings[i].normalized() : Vector3(0, 1, 0);
        p.facing = vec(n);
        p.radius = i < radii.size() ? std::max(radii[i], 0.01f) : 0.15f;
        p.plate = i < plates.size() && plates[i] != 0;
        p.drum = i < drums.size() ? int(drums[i]) : -1;
        p.depth = i < insides.size() ? std::max(insides[i], 0.0f) : 0.0f;
        p.inside = p.depth > 0.0f;
    }
    engine_->setSourceParts(id, parts);
}
void StudioSimAudio::set_source_output(int id, int bus) { if (engine_) engine_->setSourceOutput(id, bus); }
void StudioSimAudio::set_source_input_channel(int id, int channel) { if (engine_) engine_->setSourceInputChannel(id, channel); }
void StudioSimAudio::set_source_input(int id, bool on) { if (engine_) engine_->setSourceInput(id, on); }

void StudioSimAudio::set_amp_control(int id, const String& control, float value) {
    static const char* const kNames[sr::kAmpControls] = {"gain", "bass", "mid", "treble", "presence", "master"};
    for (int c = 0; c < sr::kAmpControls; ++c)
        if (control == kNames[c] && engine_) engine_->setAmpControl(id, sr::AmpControl(c), value);
}

void StudioSimAudio::set_amp_head(int id, const String& head, bool on) {
    static const char* const kNames[sr::kAmpHeads] = {"clean", "crunch", "high_gain", "bass_round", "bass_punch"};
    for (int h = 0; h < sr::kAmpHeads; ++h)
        if (head == kNames[h] && engine_) engine_->setAmpHead(id, sr::AmpHead(h), on);
}

void StudioSimAudio::set_amp_speaker(int id, const String& speaker) {
    static const char* const kNames[sr::kAmpSpeakers] = {"british_25", "british_60", "american_vintage", "british_alnico",
                                                         "american_10", "bass_10", "bass_15"};
    for (int k = 0; k < sr::kAmpSpeakers; ++k)
        if (speaker == kNames[k] && engine_) engine_->setAmpSpeaker(id, sr::AmpSpeaker(k));
}

void StudioSimAudio::set_amp_loop_mix(int id, float mix) {
    if (engine_) engine_->setAmpLoopMix(id, mix);
}

void StudioSimAudio::set_amp_input_gain(int id, float db) {
    if (engine_) engine_->setAmpInputGain(id, db);
}

// What reaches an amp's pedals, after its input level: [peak since last asked, RMS], linear.
PackedFloat32Array StudioSimAudio::get_amp_input_level(int id) {
    float peak = 0.0f, rms = 0.0f;
    if (engine_) engine_->ampInputLevel(id, peak, rms);
    PackedFloat32Array out;
    out.push_back(peak);
    out.push_back(rms);
    return out;
}

void StudioSimAudio::set_amp_cabinet(int id, const String& cabinet, bool on) {
    static const char* const kNames[sr::kAmpCabinets] = {"1x12", "2x12", "4x12", "1x15", "4x10", "8x10"};
    for (int c = 0; c < sr::kAmpCabinets; ++c)
        if (cabinet == kNames[c] && engine_) engine_->setAmpCabinet(id, sr::AmpCabinet(c), on);
}

bool StudioSimAudio::looper(int id, const String& action) {
    static const char* const kNames[] = {"press", "stop", "play", "undo", "redo", "clear"};
    for (int a = 0; a < 6; ++a)
        if (action == kNames[a]) return engine_ && engine_->looperAction(id, sr::Looper::Action(a));
    return false;
}


Dictionary StudioSimAudio::get_looper(int id) const {
    static const char* const kStates[] = {"empty", "waiting", "recording", "playing", "overdubbing", "stopped"};
    Dictionary d;
    if (!engine_) return d;
    const sr::LooperStatus st = engine_->looperStatus(id);
    d["state"] = st.present ? String(kStates[int(st.state)]) : String("none");
    d["length"] = st.length;
    d["position"] = st.position;
    d["capacity"] = st.capacity;
    d["can_undo"] = st.can_undo;
    d["can_redo"] = st.can_redo;
    return d;
}

int StudioSimAudio::add_pedal(int id, const String& kind, int at) {
    for (int k = 0; k < sr::kPedalKinds; ++k)
        if (kind == kPedalNames[k]) return engine_ ? engine_->addPedal(id, sr::PedalKind(k), at) : -1;
    return -1;
}
bool StudioSimAudio::remove_pedal(int id, int index) { return engine_ && engine_->removePedal(id, index); }
bool StudioSimAudio::move_pedal(int id, int from, int to, int loop) { return engine_ && engine_->movePedal(id, from, to, loop); }
bool StudioSimAudio::set_pedal_loop(int id, int loop) { return engine_ && engine_->setPedalLoop(id, loop); }
int StudioSimAudio::get_pedal_loop(int id) const { return engine_ ? engine_->pedalLoop(id) : 0; }
int StudioSimAudio::copy_pedal(int from_id, int index, int to_id, int at, int loop) {
    std::string err;
    const int placed = engine_ ? engine_->copyPedal(from_id, index, to_id, at, &err, loop) : -1;
    if (placed < 0) error_ = str(err.empty() ? std::string("the audio engine isn't running") : err);
    return placed;
}
void StudioSimAudio::set_pedal_on(int id, int index, bool on) { if (engine_) engine_->setPedalOn(id, index, on); }
void StudioSimAudio::set_pedal_control(int id, int index, int control, float value) {
    if (engine_) engine_->setPedalControl(id, index, control, value);
}
int StudioSimAudio::get_max_pedals() const { return sr::kMaxPedals; }

Array StudioSimAudio::get_pedals(int id) const {
    Array out;
    if (!engine_) return out;
    for (const sr::PedalStatus& p : engine_->pedals(id)) {
        Dictionary d;
        d["kind"] = String(kPedalNames[int(p.kind)]);
        d["on"] = p.on;
        d["in_loop"] = p.in_loop;
        Array controls;
        for (float v : p.controls) controls.push_back(v);
        d["controls"] = controls;
        d["plugin_id"] = str(p.plugin.id);
        d["plugin_name"] = str(p.plugin.name);
        d["plugin_maker"] = str(p.plugin.maker);
        d["editor_open"] = p.editor_open;
        out.push_back(d);
    }
    return out;
}

Dictionary StudioSimAudio::get_tuner(int id) const {
    Dictionary d;
    const sr::TunerReading r = engine_ ? engine_->tuner(id) : sr::TunerReading{};
    d["listening"] = r.listening;
    d["pitched"] = r.pitched;
    d["frequency"] = r.frequency;
    d["note"] = r.note;
    d["cents"] = r.cents;
    return d;
}

Array StudioSimAudio::get_plugins() const {
    keepScanRecord();
    Array out;
    for (const sr::PluginDescription& p : sr::AudioEngine::effectPlugins()) {
        Dictionary d;
        d["id"] = str(p.id);
        d["name"] = str(p.name);
        d["maker"] = str(p.maker);
        d["category"] = str(p.category);
        d["format"] = str(p.format);
        out.push_back(d);
    }
    return out;
}

bool StudioSimAudio::load_pedal_plugin(int id, int index, const String& plugin_id, const PackedByteArray& state) {
    std::string err;
    const std::vector<uint8_t> settings = bytes(state);
    if (engine_ && engine_->loadPedalPlugin(id, index, str(plugin_id), &err, settings.empty() ? nullptr : &settings)) return true;
    error_ = str(err.empty() ? std::string("the audio engine isn't running") : err);
    return false;
}

Array StudioSimAudio::get_instrument_plugins() const {
    keepScanRecord();
    Array out;
    for (const sr::PluginDescription& p : sr::AudioEngine::instrumentPlugins()) {
        Dictionary d;
        d["id"] = str(p.id);
        d["name"] = str(p.name);
        d["maker"] = str(p.maker);
        d["category"] = str(p.category);
        d["format"] = str(p.format);
        out.push_back(d);
    }
    return out;
}

bool StudioSimAudio::set_instrument_plugin(int id, const String& plugin_id, const PackedByteArray& state) {
    std::string err;
    const std::vector<uint8_t> settings = bytes(state);
    if (engine_ && engine_->setInstrumentPlugin(id, str(plugin_id), &err, settings.empty() ? nullptr : &settings)) return true;
    error_ = str(err.empty() ? std::string("the audio engine isn't running") : err);
    return false;
}

Dictionary StudioSimAudio::get_instrument_plugin(int id) const {
    Dictionary d;
    const sr::PluginDescription p = engine_ ? engine_->instrumentPlugin(id) : sr::PluginDescription{};
    d["plugin_id"] = str(p.id);
    d["plugin_name"] = str(p.name);
    d["plugin_maker"] = str(p.maker);
    d["editor_open"] = engine_ && engine_->instrumentEditorOpen(id);
    return d;
}

void StudioSimAudio::place_instrument_editor(int id, float above_bottom) {
    if (engine_) engine_->placeInstrumentEditor(id, above_bottom);
}

bool StudioSimAudio::show_instrument_editor(int id, bool show, const String& title) {
    return engine_ && engine_->showInstrumentEditor(id, show, str(title));
}

bool StudioSimAudio::show_plugin_editor(int id, int index, bool show, const String& title) {
    return engine_ && engine_->showPluginEditor(id, index, show, str(title));
}

Array StudioSimAudio::get_inserts(int id) const {
    Array out;
    if (!engine_) return out;
    for (const sr::PedalStatus& p : engine_->inserts(id)) {
        Dictionary d;
        d["on"] = p.on;
        d["plugin_id"] = str(p.plugin.id);
        d["plugin_name"] = str(p.plugin.name);
        d["plugin_maker"] = str(p.plugin.maker);
        d["editor_open"] = p.editor_open;
        out.push_back(d);
    }
    return out;
}

bool StudioSimAudio::set_insert(int id, int slot, const String& plugin_id, const PackedByteArray& state) {
    std::string err;
    const std::vector<uint8_t> settings = bytes(state);
    if (engine_ && engine_->setInsert(id, slot, str(plugin_id), &err, settings.empty() ? nullptr : &settings)) return true;
    error_ = str(err.empty() ? std::string("the audio engine isn't running") : err);
    return false;
}
PackedByteArray StudioSimAudio::get_plugin_state(int id, const String& place, int index) const {
    return engine_ ? bytes(engine_->pluginState(id, placeOf(place), index)) : PackedByteArray();
}
bool StudioSimAudio::set_plugin_state(int id, const String& place, int index, const PackedByteArray& state) {
    return engine_ && engine_->setPluginState(id, placeOf(place), index, bytes(state));
}
PackedStringArray StudioSimAudio::get_factory_presets(int id, const String& place, int index) const {
    PackedStringArray out;
    if (engine_)
        for (const std::string& name : engine_->factoryPresets(id, placeOf(place), index)) out.push_back(str(name));
    return out;
}
bool StudioSimAudio::load_factory_preset(int id, const String& place, int index, int preset) {
    return engine_ && engine_->loadFactoryPreset(id, placeOf(place), index, preset);
}
Array StudioSimAudio::get_plugin_parameters(int id, const String& place, int index) const {
    Array out;
    if (!engine_) return out;
    const sr::PluginPlace where = placeOf(place);
    for (const sr::PluginParameter& p : engine_->pluginParameters(id, where, index)) {
        Dictionary d;
        d["id"] = int64_t(p.id);
        d["name"] = str(p.name);
        d["unit"] = str(p.unit);
        d["min"] = p.min;
        d["max"] = p.max;
        d["default"] = p.initial;
        d["value"] = engine_->pluginParameter(id, where, index, p.id);
        out.push_back(d);
    }
    return out;
}
String StudioSimAudio::get_plugin_parameter_text(int id, const String& place, int index, int param, float value) const {
    return engine_ ? str(engine_->pluginParameterText(id, placeOf(place), index, uint32_t(param), value)) : String();
}
void StudioSimAudio::set_vst3_search_paths(const PackedStringArray& paths) {
    std::vector<std::string> list;
    for (int64_t i = 0; i < paths.size(); ++i) list.push_back(str(paths[i]));
    sr::setVst3SearchPaths(list);
}
String StudioSimAudio::preset_extension(const String& plugin_id) const { return str(sr::presetExtension(str(plugin_id))); }
float StudioSimAudio::get_plugin_parameter(int id, const String& place, int index, int param) const {
    return engine_ ? engine_->pluginParameter(id, placeOf(place), index, uint32_t(param)) : 0.0f;
}
void StudioSimAudio::set_plugin_parameter(int id, const String& place, int index, int param, float value) {
    if (engine_) engine_->setPluginParameter(id, placeOf(place), index, uint32_t(param), value);
}
void StudioSimAudio::notify_plugin_parameter(int id, const String& place, int index, int param) {
    if (engine_) engine_->notifyPluginParameter(id, placeOf(place), index, uint32_t(param));
}
void StudioSimAudio::set_send(int id, int slot, int bus, float gain, bool pre, bool on) {
    if (engine_) engine_->setSend(id, slot, bus, gain, pre, on);
}
namespace {
sr::AudioEngine::Monitor monitorOf(const String& which) {
    return which == "room" ? sr::AudioEngine::Monitor::Room : sr::AudioEngine::Monitor::Mix;
}
}  // namespace
void StudioSimAudio::set_master_automation(const Array& volume, const String& which) {
    if (!engine_) return;
    std::vector<sr::AutoPoint> points;
    for (int64_t i = 0; i < volume.size(); ++i) {
        const Array p = volume[i];
        if (p.size() >= 2) points.push_back({double(p[0]), float(p[1])});
    }
    engine_->setMasterAutomation(points, monitorOf(which));
}
void StudioSimAudio::set_master_automation_read(bool read, const String& which) {
    if (engine_) engine_->setMasterAutomationRead(read, monitorOf(which));
}
bool StudioSimAudio::write_plugin_preset(const String& path, const String& name, const PackedByteArray& state) {
    std::string err;
    if (sr::writePluginPreset(str(path), str(name), bytes(state), &err)) return true;
    error_ = str(err);
    return false;
}
Dictionary StudioSimAudio::read_plugin_preset(const String& path) {
    Dictionary d;
    sr::PluginPresetFile file;
    std::string err;
    if (!sr::readPluginPreset(str(path), &file, &err)) {
        error_ = str(err);
        return d;
    }
    d["plugin_id"] = str(file.plugin_id);
    d["name"] = str(file.name);
    d["state"] = bytes(file.state);
    return d;
}
bool StudioSimAudio::clear_insert(int id, int slot) { return engine_ && engine_->clearInsert(id, slot); }
void StudioSimAudio::set_insert_on(int id, int slot, bool on) { if (engine_) engine_->setInsertOn(id, slot, on); }
bool StudioSimAudio::show_insert_editor(int id, int slot, bool show, const String& title) {
    return engine_ && engine_->showInsertEditor(id, slot, show, str(title));
}
int StudioSimAudio::get_max_inserts() const { return sr::AudioEngine::kMaxInserts; }
bool StudioSimAudio::move_insert(int from_id, int from_slot, int to_id, int to_slot) {
    return engine_ && engine_->moveInsert(from_id, from_slot, to_id, to_slot);
}
bool StudioSimAudio::copy_insert(int from_id, int from_slot, int to_id, int to_slot) {
    std::string err;
    if (engine_ && engine_->copyInsert(from_id, from_slot, to_id, to_slot, &err)) return true;
    error_ = str(err.empty() ? std::string("the audio engine isn't running") : err);
    return false;
}

void StudioSimAudio::set_listener(const Transform3D& t) {
    if (!engine_) return;
    // Godot and Steam Audio share conventions: -Z is ahead, +Y is up.
    engine_->setListener(vec(t.origin), vec(-t.basis.get_column(2).normalized()), vec(t.basis.get_column(1).normalized()));
}

void StudioSimAudio::note_on(int id, int note, float velocity) { if (engine_) engine_->noteOn(id, note, velocity); }
void StudioSimAudio::note_off(int id, int note) { if (engine_) engine_->noteOff(id, note); }
void StudioSimAudio::all_notes_off(int id) { if (engine_) engine_->allNotesOff(id); }
void StudioSimAudio::set_binaural(bool on) { if (engine_) engine_->setBinaural(on); }
void StudioSimAudio::set_reverb(bool on) { if (engine_) engine_->setReverb(on); }
void StudioSimAudio::set_reverb_level(float gain) { if (engine_) engine_->setReverbLevel(gain); }
void StudioSimAudio::set_master_volume(float gain) { if (engine_) engine_->setMasterVolume(gain); }
void StudioSimAudio::set_room_volume(float gain) { if (engine_) engine_->setRoomVolume(gain); }
void StudioSimAudio::set_monitor(const String& which) {
    if (engine_) engine_->setMonitor(which == "mix" ? sr::AudioEngine::Monitor::Mix : sr::AudioEngine::Monitor::Room);
}
void StudioSimAudio::set_mix_output(int left, int right) { if (engine_) engine_->setMixOutput(left, right); }
void StudioSimAudio::set_master_output(int left, int right, const String& which) {
    if (engine_) engine_->setMasterOutput(left, right, monitorOf(which));
}
void StudioSimAudio::set_master_inserts(int bus, const String& which) { if (engine_) engine_->setMasterInserts(bus, monitorOf(which)); }
void StudioSimAudio::set_source_room_gain(int id, float gain) { if (engine_) engine_->setSourceRoomGain(id, gain); }
void StudioSimAudio::set_source_room_muted(int id, bool muted) { if (engine_) engine_->setSourceRoomMuted(id, muted); }
float StudioSimAudio::get_source_room_level(int id) const { return engine_ ? engine_->sourceRoomLevel(id) : 0.0f; }
float StudioSimAudio::get_source_room_peak(int id) { return engine_ ? engine_->sourceRoomPeak(id) : 0.0f; }
void StudioSimAudio::set_distance_falloff(float db_per_doubling) { if (engine_) engine_->setDistanceFalloff(db_per_doubling); }
void StudioSimAudio::set_limiter(bool on) { if (engine_) engine_->setLimiter(on); }
void StudioSimAudio::set_master_limiter(bool on, const String& which) { if (engine_) engine_->setMasterLimiter(on, monitorOf(which)); }
void StudioSimAudio::set_limiter_ceiling(float db) { if (engine_) engine_->setLimiterCeiling(db); }
void StudioSimAudio::set_delay_compensation(bool on) { if (engine_) engine_->setDelayCompensation(on); }
void StudioSimAudio::refresh_delay_compensation() { if (engine_) engine_->refreshDelayCompensation(); }

Dictionary StudioSimAudio::get_delay_compensation() const {
    Dictionary d;
    Dictionary tracks;
    d["on"] = engine_ ? engine_->delayCompensation() : false;
    d["total"] = engine_ ? engine_->compensationTotal() : 0;
    d["sample_rate"] = engine_ ? engine_->sampleRate() : 48000;
    for (int id = 0; engine_ && id < sr::AudioEngine::kSourceSlots; ++id) {
        if (!engine_->hasSource(id)) continue;
        const sr::AudioEngine::TrackDelay t = engine_->trackDelay(id);
        Dictionary track;
        track["delay"] = t.delay;
        track["compensation"] = t.compensation;
        track["over"] = t.over;
        tracks[id] = track;
    }
    d["tracks"] = tracks;
    return d;
}

Dictionary StudioSimAudio::read_meter() {
    Dictionary d;
    if (!engine_) return d;
    const sr::MeterReading m = engine_->readMeter();
    d["peak_l"] = m.peak_l;
    d["peak_r"] = m.peak_r;
    d["rms_l"] = m.rms_l;
    d["rms_r"] = m.rms_r;
    d["limiter_gain"] = m.limiter_gain;
    d["mix_limiter_gain"] = m.mix_limiter_gain;
    d["room_limiter_gain"] = m.room_limiter_gain;
    d["clipped"] = int64_t(m.clipped);
    d["reverb_peak_l"] = m.reverb_peak_l;
    d["reverb_peak_r"] = m.reverb_peak_r;
    d["reverb_rms_l"] = m.reverb_rms_l;
    d["reverb_rms_r"] = m.reverb_rms_r;
    d["room_peak_l"] = m.room_peak_l;
    d["room_peak_r"] = m.room_peak_r;
    d["room_rms_l"] = m.room_rms_l;
    d["room_rms_r"] = m.room_rms_r;
    d["mix_peak_l"] = m.mix_peak_l;
    d["mix_peak_r"] = m.mix_peak_r;
    d["mix_rms_l"] = m.mix_rms_l;
    d["mix_rms_r"] = m.mix_rms_r;
    return d;
}
void StudioSimAudio::set_source_volume(int id, float gain) { if (engine_) engine_->setSourceVolume(id, gain); }
void StudioSimAudio::set_source_polarity(int id, bool inverted) { if (engine_) engine_->setSourcePolarity(id, inverted); }
float StudioSimAudio::get_source_level(int id, bool pre_fader) const { return engine_ ? engine_->sourceLevel(id, pre_fader) : 0.0f; }
float StudioSimAudio::get_source_peak(int id, bool pre_fader) { return engine_ ? engine_->sourcePeak(id, pre_fader) : 0.0f; }
PackedFloat32Array StudioSimAudio::get_source_levels(int id, bool pre_fader) const {
    float l = 0.0f, r = 0.0f;
    if (engine_) engine_->sourceLevels(id, pre_fader, l, r);
    PackedFloat32Array out;
    out.push_back(l);
    out.push_back(r);
    return out;
}
PackedFloat32Array StudioSimAudio::get_source_peaks(int id, bool pre_fader) {
    float l = 0.0f, r = 0.0f;
    if (engine_) engine_->sourcePeaks(id, pre_fader, l, r);
    PackedFloat32Array out;
    out.push_back(l);
    out.push_back(r);
    return out;
}
float StudioSimAudio::get_source_reduction(int id) { return engine_ ? engine_->sourceReduction(id) : 0.0f; }

Dictionary StudioSimAudio::get_stats() const {
    Dictionary d;
    if (!engine_) return d;
    const sr::EngineStats s = engine_->stats();
    d["device_running"] = s.device_running;
    d["device_reset"] = s.device_reset;
    d["desktop_audio"] = engine_->desktopAudioRunning();
    d["desktop_audio_ms"] = engine_->desktopAudioHeldMs();
    d["backend"] = str(s.backend);
    d["output_device"] = str(s.output_device);
    d["output_channels"] = s.output_channels;
    d["sample_rate"] = s.sample_rate;
    d["device_rate"] = s.device_rate;
    d["block_size"] = s.block_size;
    d["device_period"] = s.device_period;
    d["buffer_ms"] = s.buffer_ms;
    d["device_ms"] = s.device_ms;
    d["binaural_ms"] = s.binaural_ms;
    d["compensation_ms"] = s.compensation_ms;
    d["output_latency_ms"] = s.output_latency_ms;
    d["live_input"] = s.live_input;
    d["input_device"] = str(s.input_device);
    d["input_channels"] = s.input_channels;
    d["input_latency_ms"] = s.input_latency_ms;
    d["cpu_load"] = s.cpu_load;
    d["blocks"] = int64_t(s.blocks);
    d["disk_misses"] = int64_t(s.disk_misses);
    d["disk_mb"] = s.disk_mb;
    return d;
}

// ── The sequencer ──────────────────────────────────────────────────────────────────────────────────────────
void StudioSimAudio::load_default_pattern(int id) { if (engine_) engine_->loadDefaultPattern(id); }

Array StudioSimAudio::get_pattern(int id) const {
    Array out;
    if (!engine_) return out;
    for (const sr::PatternNote& n : engine_->pattern(id)) {
        Dictionary note;
        note["step"] = n.step;
        note["note"] = n.note;
        note["length"] = n.length;
        note["velocity"] = n.velocity;
        note["chance"] = n.chance;
        out.push_back(note);
    }
    return out;
}

void StudioSimAudio::set_pattern(int id, const Array& notes) {
    if (!engine_) return;
    std::vector<sr::PatternNote> pattern;
    for (int64_t i = 0; i < notes.size(); ++i) {
        const Dictionary note = notes[i];
        pattern.push_back({int(note.get("step", 0)), int(note.get("note", 60)), float(note.get("length", 1.0)),
                           float(note.get("velocity", 0.8)), float(note.get("chance", 1.0))});
    }
    engine_->setPattern(id, pattern);
}

bool StudioSimAudio::set_pattern_note(int id, int step, int note, float length, float velocity, float chance) {
    return engine_ && engine_->setPatternNote(id, {step, note, length, velocity, chance});
}

void StudioSimAudio::remove_pattern_note(int id, int step, int note) { if (engine_) engine_->removePatternNote(id, step, note); }
void StudioSimAudio::set_pattern_steps(int id, int steps) { if (engine_) engine_->setPatternSteps(id, steps); }
int StudioSimAudio::get_pattern_steps(int id) const { return engine_ ? engine_->patternSteps(id) : 0; }
void StudioSimAudio::set_source_loop(int id, bool on) { if (engine_) engine_->setSourceLoop(id, on); }
void StudioSimAudio::set_sequencer_running(bool on) { if (engine_) engine_->setSequencerRunning(on); }
void StudioSimAudio::start_sequencer_in(double seconds, int from_step) { if (engine_) engine_->startSequencerIn(seconds, from_step); }
void StudioSimAudio::nudge_sequencer(double seconds) { if (engine_) engine_->nudgeSequencer(seconds); }
double StudioSimAudio::get_sequencer_step_now() const { return engine_ ? engine_->sequencerStepNow() : -1.0; }
void StudioSimAudio::set_sustain(int id, bool down) { if (engine_) engine_->setSustain(id, down); }
void StudioSimAudio::share_played_notes(bool on) { if (engine_) engine_->sharePlayedNotes(on); }

String StudioSimAudio::start_desktop_audio(bool capture) {
    if (!ensureEngine()) return error_;
    std::string error;
    return engine_->startDesktopAudio(&error, capture) ? String() : String(error.c_str());
}
void StudioSimAudio::stop_desktop_audio() { if (engine_) engine_->stopDesktopAudio(); }
bool StudioSimAudio::is_desktop_audio_on() const { return engine_ && engine_->desktopAudioRunning(); }

String StudioSimAudio::start_net_audio(bool host, const String& address, int port, int me) {
    if (!engine_) return "the audio isn't running";
    std::string error;
    return engine_->startNetAudio(host, address.utf8().get_data(), port, me, &error) ? String() : String(error.c_str());
}
void StudioSimAudio::stop_net_audio() { if (engine_) engine_->stopNetAudio(); }
bool StudioSimAudio::send_net_datagram(const String& address, int port, const PackedByteArray& data) {
    if (!engine_) return false;
    return engine_->sendNetDatagram(address.utf8().get_data(), port, std::vector<uint8_t>(data.ptr(), data.ptr() + data.size()));
}
void StudioSimAudio::set_net_players(const PackedInt32Array& ids) {
    if (!engine_) return;
    std::vector<int> players;
    for (int i = 0; i < ids.size(); ++i) players.push_back(ids[i]);
    engine_->setNetPlayers(players);
}
bool StudioSimAudio::send_source_to_net(int id, int number) { return engine_ && engine_->sendSourceToNet(id, number); }
bool StudioSimAudio::feed_source_from_net(int id, int player, int number) { return engine_ && engine_->feedSourceFromNet(id, player, number); }
Dictionary StudioSimAudio::get_net_stats(int id) const {
    Dictionary d;
    if (!engine_) return d;
    const sr::NetAudio::Stats st = engine_->netStats(id);
    d["frames"] = int64_t(st.frames);
    d["lost"] = int64_t(st.lost);
    d["late"] = int64_t(st.late);
    d["held_ms"] = st.held_ms;
    d["hold_ms"] = st.hold_ms;
    return d;
}

Array StudioSimAudio::take_played_notes() {
    Array out;
    if (!engine_) return out;
    std::vector<sr::AudioEngine::PlayedNote> notes;
    engine_->takePlayedNotes(notes);
    for (const auto& n : notes) {
        Array entry;
        entry.push_back(n.id);
        entry.push_back(String(n.type == sr::MidiEvent::NoteOn ? "on" : n.type == sr::MidiEvent::NoteOff ? "off" : "sustain"));
        entry.push_back(n.note);
        entry.push_back(n.velocity);
        out.push_back(entry);
    }
    return out;
}

void StudioSimAudio::play_from(double step, double in_seconds) { if (engine_) engine_->playFrom(step, in_seconds); }
void StudioSimAudio::set_loop_range(bool on, double start_step, double end_step) { if (engine_) engine_->setLoopRange(on, start_step, end_step); }
double StudioSimAudio::get_timeline_position() const { return engine_ ? engine_->timelinePosition() : 0.0; }

bool StudioSimAudio::set_track(int id, const Array& notes, const Array& clips, const Dictionary& automation) {
    if (!engine_) return false;
    std::vector<sr::TimelineNote> n;
    for (int64_t i = 0; i < notes.size(); ++i) {
        const Dictionary d = notes[i];
        n.push_back({double(d.get("step", 0.0)), float(d.get("length", 1.0)), int(d.get("note", 60)), float(d.get("velocity", 0.8))});
    }
    std::vector<sr::ClipSpec> c;
    for (int64_t i = 0; i < clips.size(); ++i) {
        const Dictionary d = clips[i];
        c.push_back({str(String(d.get("path", ""))), double(d.get("start", 0.0)), double(d.get("offset", 0.0)), double(d.get("length", 0.0)),
                     double(d.get("fade_in", 0.0)), double(d.get("fade_out", 0.0)), float(d.get("gain", 1.0)), bool(d.get("direct", false))});
    }
    sr::TrackAutomation lanes;  // {volume, mute, sustain}: each [[step, value], ...]
    const std::pair<const char*, std::vector<sr::AutoPoint>*> named[3] = {{"volume", &lanes.volume}, {"mute", &lanes.mute}, {"sustain", &lanes.sustain}};
    auto read = [](const Array& points, std::vector<sr::AutoPoint>* lane) {
        for (int64_t i = 0; i < points.size(); ++i) {
            const Array p = points[i];
            if (p.size() >= 2) lane->push_back({double(p[0]), float(p[1])});
        }
    };
    for (const auto& [name, lane] : named) read(automation.get(name, Array()), lane);
    // Its controls: [{target ("amp", "insert", "pedal", "instrument", "send" or "stomp": a stock pedal's knob), index, param, points}]
    const Array params = automation.get("params", Array());
    for (int64_t i = 0; i < params.size(); ++i) {
        const Dictionary d = params[i];
        sr::ParamLane lane;
        const String target = d.get("target", "amp");
        lane.target = target == "insert" ? sr::ParamLane::Insert : target == "pedal" ? sr::ParamLane::Pedal
                    : target == "instrument" ? sr::ParamLane::Instrument : target == "send" ? sr::ParamLane::Send
                    : target == "stomp" ? sr::ParamLane::PedalKnob : target == "pan" ? sr::ParamLane::Pan : sr::ParamLane::AmpKnob;
        lane.index = int(d.get("index", 0));
        lane.param = uint32_t(int64_t(d.get("param", 0)));
        read(d.get("points", Array()), &lane.points);
        std::stable_sort(lane.points.begin(), lane.points.end(), [](const sr::AutoPoint& a, const sr::AutoPoint& b) { return a.step < b.step; });
        lanes.params.push_back(std::move(lane));
    }
    std::string err;
    if (engine_->setTrack(id, n, c, &err, lanes)) return true;
    error_ = str(err);
    return false;
}

PackedFloat32Array StudioSimAudio::get_audio_peaks(const String& path, double per_second) {
    PackedFloat32Array out;
    if (engine_)
        for (float v : engine_->audioPeaks(str(path), per_second)) out.push_back(v);
    return out;
}

double StudioSimAudio::get_audio_seconds(const String& path) { return engine_ ? engine_->audioSeconds(str(path)) : 0.0; }

void StudioSimAudio::set_record_arm(int id, bool armed) { if (engine_) engine_->setRecordArm(id, armed); }

bool StudioSimAudio::start_recording(const Array& files, double from_step, double count_in_steps, bool loop, double preroll_steps,
                                     double punch_out_step, double in_seconds) {
    if (!engine_) return false;
    std::vector<std::pair<int, std::string>> f;
    for (int64_t i = 0; i < files.size(); ++i) {  // [id, path], or [id, path, true] for an amp's DI
        const Array pair = files[i];
        if (pair.size() >= 2) f.emplace_back(int(pair[0]) + (pair.size() >= 3 && bool(pair[2]) ? sr::kDiTake : 0), str(String(pair[1])));
    }
    std::string err;
    if (engine_->startRecording(f, from_step, &err, count_in_steps, loop, preroll_steps, punch_out_step, in_seconds)) return true;
    error_ = str(err);
    return false;
}

void StudioSimAudio::stop_recording() { if (engine_) engine_->stopRecording(); }
int StudioSimAudio::get_count_in() const { return engine_ ? engine_->countInLeft() : 0; }
bool StudioSimAudio::is_recording() const { return engine_ && engine_->recording(); }

Dictionary StudioSimAudio::take_recording() {
    Dictionary d;
    sr::RecordingResult r;
    if (!engine_ || !engine_->takeRecording(&r)) return d;
    d["start_step"] = r.start_step;
    d["end_step"] = r.end_step;
    d["step_seconds"] = r.step_seconds;
    Array audio;
    for (const auto& a : r.audio) {
        Dictionary e;
        e["source"] = a.source >= sr::kDiTake ? a.source - sr::kDiTake : a.source;
        if (a.source >= sr::kDiTake) e["di"] = true;  // (an amp's DI, beside what it played)
        e["path"] = str(a.path);
        e["seconds"] = a.seconds;
        e["dropped"] = int64_t(a.dropped);
        audio.push_back(e);
    }
    d["audio"] = audio;
    Array notes;
    for (const auto& n : r.notes) {
        Dictionary e;
        e["source"] = n.source;
        e["step"] = n.note.step;
        e["length"] = n.note.length;
        e["note"] = n.note.note;
        e["velocity"] = n.note.velocity;
        notes.push_back(e);
    }
    d["notes"] = notes;
    Array pedal;
    for (const auto& p : r.sustain) {
        Dictionary e;
        e["source"] = p.source;
        e["step"] = p.step;
        e["on"] = p.on;
        pedal.push_back(e);
    }
    d["sustain"] = pedal;
    return d;
}

void StudioSimAudio::set_automation_read(int id, bool volume, bool mute, bool sustain, bool params) {
    if (engine_) engine_->setAutomationRead(id, volume, mute, sustain, params);
}
void StudioSimAudio::set_tempo(float bpm) { if (engine_) engine_->setTempo(bpm); }
void StudioSimAudio::set_swing(float amount) { if (engine_) engine_->setSwing(amount); }
void StudioSimAudio::set_click(bool on) { if (engine_) engine_->setClick(on); }
void StudioSimAudio::set_click_volume(float gain) { if (engine_) engine_->setClickVolume(gain); }

Dictionary StudioSimAudio::get_transport() const {
    Dictionary d;
    if (!engine_) return d;
    const sr::TransportState t = engine_->transport();
    d["running"] = t.running;
    d["bpm"] = t.bpm;
    d["swing"] = t.swing;
    d["click"] = t.click;
    d["click_volume"] = t.click_volume;
    d["step"] = t.step;
    return d;
}

Array StudioSimAudio::get_drum_pieces(const String& kind) const {
    Array out;
    const bool garage = kind == "garage_drums" || kind == "studio_drums";  // the acoustic kits, with their ride
    for (int piece = 0; piece < sr::Drums::kPieces; ++piece) {
        const auto p = sr::Drums::Piece(piece);
        Dictionary entry;
        entry["name"] = String(garage ? sr::AcousticKit::pieceName(p) : sr::Drums::pieceName(p));
        entry["note"] = garage ? sr::AcousticKit::noteFor(p) : sr::Drums::noteFor(p);
        out.push_back(entry);
    }
    return out;
}

String StudioSimAudio::get_drum_piece_name(int note, const String& kind) const {
    const bool acoustic = kind == "garage_drums" || kind == "studio_drums";
    const auto piece = acoustic ? sr::AcousticKit::pieceFor(note) : sr::Drums::pieceFor(note);
    return String(acoustic ? sr::AcousticKit::pieceName(piece) : sr::Drums::pieceName(piece));
}

// ── MIDI ───────────────────────────────────────────────────────────────────────────────────────────────────
bool StudioSimAudio::start_midi() {
    if (!ensureEngine()) return false;
    std::string err;
    if (engine_->startMidi(&err)) return true;
    error_ = str(err);
    return false;
}

void StudioSimAudio::poll_midi() { if (engine_) engine_->pollMidi(); }

Array StudioSimAudio::get_midi_devices() const {
    Array out;
    if (!engine_) return out;
    for (const sr::MidiDeviceInfo& d : engine_->midiDevices()) {
        Dictionary entry;
        entry["name"] = str(d.name);
        entry["enabled"] = d.enabled;
        entry["events"] = int64_t(d.events);
        out.push_back(entry);
    }
    return out;
}

void StudioSimAudio::set_midi_device_enabled(const String& name, bool enabled) {
    if (ensureEngine()) engine_->setMidiDeviceEnabled(str(name), enabled);
}

int StudioSimAudio::get_midi_event_count() const { return engine_ ? int(engine_->midiEventCount()) : 0; }

void StudioSimAudio::_bind_methods() {
    ClassDB::bind_method(D_METHOD("start", "silent"), &StudioSimAudio::start, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("open_device", "config"), &StudioSimAudio::open_device);
    ClassDB::bind_method(D_METHOD("get_device_config"), &StudioSimAudio::get_device_config);
    ClassDB::bind_method(D_METHOD("get_output_devices"), &StudioSimAudio::get_output_devices);
    ClassDB::bind_method(D_METHOD("get_input_devices"), &StudioSimAudio::get_input_devices);
    ClassDB::bind_method(D_METHOD("set_output_channels", "left", "right"), &StudioSimAudio::set_output_channels);
    ClassDB::bind_method(D_METHOD("set_live_input", "enabled"), &StudioSimAudio::set_live_input);
    ClassDB::bind_method(D_METHOD("stop"), &StudioSimAudio::stop);
    ClassDB::bind_method(D_METHOD("is_running"), &StudioSimAudio::is_running);
    ClassDB::bind_method(D_METHOD("get_error"), &StudioSimAudio::get_error);

    ClassDB::bind_method(D_METHOD("add_source", "kind", "position", "gain", "reverb_send"), &StudioSimAudio::add_source);
    ClassDB::bind_method(D_METHOD("remove_source", "id"), &StudioSimAudio::remove_source);
    ClassDB::bind_method(D_METHOD("get_source_count"), &StudioSimAudio::get_source_count);
    ClassDB::bind_method(D_METHOD("get_max_sources"), &StudioSimAudio::get_max_sources);
    ClassDB::bind_method(D_METHOD("set_source_position", "id", "position"), &StudioSimAudio::set_source_position);
    ClassDB::bind_method(D_METHOD("is_source_blocked", "id"), &StudioSimAudio::is_source_blocked);
    ClassDB::bind_method(D_METHOD("set_room", "size", "walls", "surfaces"), &StudioSimAudio::set_room, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("get_room_decay_bands"), &StudioSimAudio::get_room_decay_bands);
    ClassDB::bind_method(D_METHOD("set_early_reflections", "on"), &StudioSimAudio::set_early_reflections);
    ClassDB::bind_method(D_METHOD("is_room_settled"), &StudioSimAudio::is_room_settled);
    ClassDB::bind_method(D_METHOD("get_room_decay"), &StudioSimAudio::get_room_decay);
    ClassDB::bind_method(D_METHOD("set_source_muted", "id", "muted"), &StudioSimAudio::set_source_muted);
    ClassDB::bind_method(D_METHOD("set_source_solo_muted", "id", "silenced"), &StudioSimAudio::set_source_solo_muted);
    ClassDB::bind_method(D_METHOD("get_mic_models"), &StudioSimAudio::get_mic_models);
    ClassDB::bind_method(D_METHOD("get_mic_response", "model", "frequencies"), &StudioSimAudio::get_mic_response);
    ClassDB::bind_method(D_METHOD("set_mic_model", "id", "model", "pattern", "capsule"), &StudioSimAudio::set_mic_model, DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("set_mic_aim", "id", "aim", "capsule"), &StudioSimAudio::set_mic_aim, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("set_mic_capsule", "id", "capsule", "position"), &StudioSimAudio::set_mic_capsule);
    ClassDB::bind_method(D_METHOD("set_mic_mid_side", "id", "mid_side", "width"), &StudioSimAudio::set_mic_mid_side, DEFVAL(1.0f));
    ClassDB::bind_method(D_METHOD("get_mic_noise", "model"), &StudioSimAudio::get_mic_noise);
    ClassDB::bind_method(D_METHOD("quit_process", "code"), &StudioSimAudio::quit_process);
    ClassDB::bind_method(D_METHOD("set_source_pan", "id", "pan"), &StudioSimAudio::set_source_pan);
    ClassDB::bind_method(D_METHOD("set_bus_mono", "id", "mono"), &StudioSimAudio::set_bus_mono);
    ClassDB::bind_method(D_METHOD("set_bus_pans", "id", "left", "right"), &StudioSimAudio::set_bus_pans);
    ClassDB::bind_method(D_METHOD("set_source_parts", "id", "centres", "facings", "radii", "plates", "drums", "insides"),
                         &StudioSimAudio::set_source_parts, DEFVAL(PackedInt32Array()), DEFVAL(PackedFloat32Array()));
    ClassDB::bind_method(D_METHOD("set_source_radiator", "id", "cones", "facing", "inches", "open_back", "back", "width", "coverage_deg",
                                  "crossover_hz"), &StudioSimAudio::set_source_radiator, DEFVAL(0.0f), DEFVAL(1800.0f));
    ClassDB::bind_method(D_METHOD("set_floor_reflection", "amount"), &StudioSimAudio::set_floor_reflection);
    ClassDB::bind_method(D_METHOD("set_amp_speaker", "id", "speaker"), &StudioSimAudio::set_amp_speaker);
    ClassDB::bind_method(D_METHOD("set_amp_loop_mix", "id", "mix"), &StudioSimAudio::set_amp_loop_mix);
    ClassDB::bind_method(D_METHOD("set_amp_input_gain", "id", "db"), &StudioSimAudio::set_amp_input_gain);
    ClassDB::bind_method(D_METHOD("get_amp_input_level", "id"), &StudioSimAudio::get_amp_input_level);
    ClassDB::bind_method(D_METHOD("set_source_output", "id", "bus"), &StudioSimAudio::set_source_output);
    ClassDB::bind_method(D_METHOD("set_source_input_channel", "id", "channel"), &StudioSimAudio::set_source_input_channel);
    ClassDB::bind_method(D_METHOD("set_source_input", "id", "on"), &StudioSimAudio::set_source_input);
    ClassDB::bind_method(D_METHOD("set_amp_control", "id", "control", "value"), &StudioSimAudio::set_amp_control);
    ClassDB::bind_method(D_METHOD("set_amp_head", "id", "head", "on"), &StudioSimAudio::set_amp_head);
    ClassDB::bind_method(D_METHOD("set_amp_cabinet", "id", "cabinet", "on"), &StudioSimAudio::set_amp_cabinet);
    ClassDB::bind_method(D_METHOD("looper", "id", "action"), &StudioSimAudio::looper);
    ClassDB::bind_method(D_METHOD("get_looper", "id"), &StudioSimAudio::get_looper);
    ClassDB::bind_method(D_METHOD("add_pedal", "id", "kind", "at"), &StudioSimAudio::add_pedal);
    ClassDB::bind_method(D_METHOD("remove_pedal", "id", "index"), &StudioSimAudio::remove_pedal);
    ClassDB::bind_method(D_METHOD("move_pedal", "id", "from", "to", "loop"), &StudioSimAudio::move_pedal, DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("set_pedal_loop", "id", "loop"), &StudioSimAudio::set_pedal_loop);
    ClassDB::bind_method(D_METHOD("get_pedal_loop", "id"), &StudioSimAudio::get_pedal_loop);
    ClassDB::bind_method(D_METHOD("copy_pedal", "from_id", "index", "to_id", "at", "loop"), &StudioSimAudio::copy_pedal, DEFVAL(-1), DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("set_pedal_on", "id", "index", "on"), &StudioSimAudio::set_pedal_on);
    ClassDB::bind_method(D_METHOD("set_pedal_control", "id", "index", "control", "value"), &StudioSimAudio::set_pedal_control);
    ClassDB::bind_method(D_METHOD("get_pedals", "id"), &StudioSimAudio::get_pedals);
    ClassDB::bind_method(D_METHOD("get_tuner", "id"), &StudioSimAudio::get_tuner);
    ClassDB::bind_method(D_METHOD("get_max_pedals"), &StudioSimAudio::get_max_pedals);
    ClassDB::bind_method(D_METHOD("get_plugins"), &StudioSimAudio::get_plugins);
    ClassDB::bind_method(D_METHOD("load_pedal_plugin", "id", "index", "plugin_id", "state"), &StudioSimAudio::load_pedal_plugin,
                         DEFVAL(PackedByteArray()));
    ClassDB::bind_method(D_METHOD("show_plugin_editor", "id", "index", "show", "title"), &StudioSimAudio::show_plugin_editor);
    ClassDB::bind_method(D_METHOD("get_inserts", "id"), &StudioSimAudio::get_inserts);
    ClassDB::bind_method(D_METHOD("set_insert", "id", "slot", "plugin_id", "state"), &StudioSimAudio::set_insert, DEFVAL(PackedByteArray()));
    ClassDB::bind_method(D_METHOD("get_instrument_plugins"), &StudioSimAudio::get_instrument_plugins);
    ClassDB::bind_method(D_METHOD("set_instrument_plugin", "id", "plugin_id", "state"), &StudioSimAudio::set_instrument_plugin,
                         DEFVAL(PackedByteArray()));
    ClassDB::bind_method(D_METHOD("get_instrument_plugin", "id"), &StudioSimAudio::get_instrument_plugin);
    ClassDB::bind_method(D_METHOD("show_instrument_editor", "id", "show", "title"), &StudioSimAudio::show_instrument_editor);
    ClassDB::bind_method(D_METHOD("place_instrument_editor", "id", "above_bottom"), &StudioSimAudio::place_instrument_editor);
    ClassDB::bind_method(D_METHOD("get_plugin_state", "id", "place", "index"), &StudioSimAudio::get_plugin_state);
    ClassDB::bind_method(D_METHOD("set_plugin_state", "id", "place", "index", "state"), &StudioSimAudio::set_plugin_state);
    ClassDB::bind_method(D_METHOD("get_factory_presets", "id", "place", "index"), &StudioSimAudio::get_factory_presets);
    ClassDB::bind_method(D_METHOD("load_factory_preset", "id", "place", "index", "preset"), &StudioSimAudio::load_factory_preset);
    ClassDB::bind_method(D_METHOD("write_plugin_preset", "path", "name", "state"), &StudioSimAudio::write_plugin_preset);
    ClassDB::bind_method(D_METHOD("read_plugin_preset", "path"), &StudioSimAudio::read_plugin_preset);
    ClassDB::bind_method(D_METHOD("clear_insert", "id", "slot"), &StudioSimAudio::clear_insert);
    ClassDB::bind_method(D_METHOD("set_insert_on", "id", "slot", "on"), &StudioSimAudio::set_insert_on);
    ClassDB::bind_method(D_METHOD("show_insert_editor", "id", "slot", "show", "title"), &StudioSimAudio::show_insert_editor);
    ClassDB::bind_method(D_METHOD("get_max_inserts"), &StudioSimAudio::get_max_inserts);
    ClassDB::bind_method(D_METHOD("move_insert", "from_id", "from_slot", "to_id", "to_slot"), &StudioSimAudio::move_insert);
    ClassDB::bind_method(D_METHOD("copy_insert", "from_id", "from_slot", "to_id", "to_slot"), &StudioSimAudio::copy_insert);
    ClassDB::bind_method(D_METHOD("set_listener", "transform"), &StudioSimAudio::set_listener);
    ClassDB::bind_method(D_METHOD("note_on", "id", "note", "velocity"), &StudioSimAudio::note_on);
    ClassDB::bind_method(D_METHOD("note_off", "id", "note"), &StudioSimAudio::note_off);
    ClassDB::bind_method(D_METHOD("all_notes_off", "id"), &StudioSimAudio::all_notes_off);
    ClassDB::bind_method(D_METHOD("set_binaural", "on"), &StudioSimAudio::set_binaural);
    ClassDB::bind_method(D_METHOD("set_reverb", "on"), &StudioSimAudio::set_reverb);
    ClassDB::bind_method(D_METHOD("set_reverb_level", "gain"), &StudioSimAudio::set_reverb_level);
    ClassDB::bind_method(D_METHOD("set_master_volume", "gain"), &StudioSimAudio::set_master_volume);
    ClassDB::bind_method(D_METHOD("set_room_volume", "gain"), &StudioSimAudio::set_room_volume);
    ClassDB::bind_method(D_METHOD("set_monitor", "which"), &StudioSimAudio::set_monitor);
    ClassDB::bind_method(D_METHOD("set_mix_output", "left", "right"), &StudioSimAudio::set_mix_output);
    ClassDB::bind_method(D_METHOD("set_master_output", "left", "right", "which"), &StudioSimAudio::set_master_output);
    ClassDB::bind_method(D_METHOD("set_master_inserts", "bus", "which"), &StudioSimAudio::set_master_inserts, DEFVAL("mix"));
    ClassDB::bind_method(D_METHOD("set_source_room_gain", "id", "gain"), &StudioSimAudio::set_source_room_gain);
    ClassDB::bind_method(D_METHOD("set_source_room_muted", "id", "muted"), &StudioSimAudio::set_source_room_muted);
    ClassDB::bind_method(D_METHOD("get_source_room_level", "id"), &StudioSimAudio::get_source_room_level);
    ClassDB::bind_method(D_METHOD("get_source_room_peak", "id"), &StudioSimAudio::get_source_room_peak);
    ClassDB::bind_method(D_METHOD("set_source_gain", "id", "gain"), &StudioSimAudio::set_source_gain);
    ClassDB::bind_method(D_METHOD("set_distance_falloff", "db_per_doubling"), &StudioSimAudio::set_distance_falloff);
    ClassDB::bind_method(D_METHOD("set_limiter", "on"), &StudioSimAudio::set_limiter);
    ClassDB::bind_method(D_METHOD("set_master_limiter", "on", "which"), &StudioSimAudio::set_master_limiter);
    ClassDB::bind_method(D_METHOD("set_limiter_ceiling", "db"), &StudioSimAudio::set_limiter_ceiling);
    ClassDB::bind_method(D_METHOD("set_delay_compensation", "on"), &StudioSimAudio::set_delay_compensation);
    ClassDB::bind_method(D_METHOD("refresh_delay_compensation"), &StudioSimAudio::refresh_delay_compensation);
    ClassDB::bind_method(D_METHOD("get_delay_compensation"), &StudioSimAudio::get_delay_compensation);
    ClassDB::bind_method(D_METHOD("read_meter"), &StudioSimAudio::read_meter);
    ClassDB::bind_method(D_METHOD("get_source_level", "id", "pre_fader"), &StudioSimAudio::get_source_level, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("get_source_peak", "id", "pre_fader"), &StudioSimAudio::get_source_peak, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("get_source_levels", "id", "pre_fader"), &StudioSimAudio::get_source_levels, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("get_source_peaks", "id", "pre_fader"), &StudioSimAudio::get_source_peaks, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("get_source_reduction", "id"), &StudioSimAudio::get_source_reduction);
    ClassDB::bind_method(D_METHOD("set_source_volume", "id", "gain"), &StudioSimAudio::set_source_volume);
    ClassDB::bind_method(D_METHOD("set_source_polarity", "id", "inverted"), &StudioSimAudio::set_source_polarity);
    ClassDB::bind_method(D_METHOD("get_stats"), &StudioSimAudio::get_stats);

    ClassDB::bind_method(D_METHOD("load_default_pattern", "id"), &StudioSimAudio::load_default_pattern);
    ClassDB::bind_method(D_METHOD("get_pattern", "id"), &StudioSimAudio::get_pattern);
    ClassDB::bind_method(D_METHOD("set_pattern", "id", "notes"), &StudioSimAudio::set_pattern);
    ClassDB::bind_method(D_METHOD("set_pattern_note", "id", "step", "note", "length", "velocity", "chance"),
                         &StudioSimAudio::set_pattern_note);
    ClassDB::bind_method(D_METHOD("remove_pattern_note", "id", "step", "note"), &StudioSimAudio::remove_pattern_note);
    ClassDB::bind_method(D_METHOD("set_pattern_steps", "id", "steps"), &StudioSimAudio::set_pattern_steps);
    ClassDB::bind_method(D_METHOD("get_pattern_steps", "id"), &StudioSimAudio::get_pattern_steps);
    ClassDB::bind_method(D_METHOD("set_source_loop", "id", "on"), &StudioSimAudio::set_source_loop);
    ClassDB::bind_method(D_METHOD("set_sequencer_running", "on"), &StudioSimAudio::set_sequencer_running);
    ClassDB::bind_method(D_METHOD("start_sequencer_in", "seconds", "from_step"), &StudioSimAudio::start_sequencer_in, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("nudge_sequencer", "seconds"), &StudioSimAudio::nudge_sequencer);
    ClassDB::bind_method(D_METHOD("get_sequencer_step_now"), &StudioSimAudio::get_sequencer_step_now);
    ClassDB::bind_method(D_METHOD("set_sustain", "id", "down"), &StudioSimAudio::set_sustain);
    ClassDB::bind_method(D_METHOD("share_played_notes", "on"), &StudioSimAudio::share_played_notes);
    ClassDB::bind_method(D_METHOD("take_played_notes"), &StudioSimAudio::take_played_notes);
    ClassDB::bind_method(D_METHOD("start_desktop_audio", "capture"), &StudioSimAudio::start_desktop_audio, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("stop_desktop_audio"), &StudioSimAudio::stop_desktop_audio);
    ClassDB::bind_method(D_METHOD("is_desktop_audio_on"), &StudioSimAudio::is_desktop_audio_on);
    ClassDB::bind_method(D_METHOD("start_net_audio", "host", "address", "port", "me"), &StudioSimAudio::start_net_audio);
    ClassDB::bind_method(D_METHOD("stop_net_audio"), &StudioSimAudio::stop_net_audio);
    ClassDB::bind_method(D_METHOD("send_net_datagram", "address", "port", "data"), &StudioSimAudio::send_net_datagram);
    ClassDB::bind_method(D_METHOD("set_net_players", "ids"), &StudioSimAudio::set_net_players);
    ClassDB::bind_method(D_METHOD("send_source_to_net", "id", "number"), &StudioSimAudio::send_source_to_net);
    ClassDB::bind_method(D_METHOD("feed_source_from_net", "id", "player", "number"), &StudioSimAudio::feed_source_from_net);
    ClassDB::bind_method(D_METHOD("get_net_stats", "id"), &StudioSimAudio::get_net_stats);
    ClassDB::bind_method(D_METHOD("play_from", "step", "in_seconds"), &StudioSimAudio::play_from, DEFVAL(-1.0));
    ClassDB::bind_method(D_METHOD("set_loop_range", "on", "start_step", "end_step"), &StudioSimAudio::set_loop_range);
    ClassDB::bind_method(D_METHOD("get_timeline_position"), &StudioSimAudio::get_timeline_position);
    ClassDB::bind_method(D_METHOD("set_track", "id", "notes", "clips", "automation"), &StudioSimAudio::set_track, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("set_automation_read", "id", "volume", "mute", "sustain", "params"), &StudioSimAudio::set_automation_read, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("get_plugin_parameters", "id", "place", "index"), &StudioSimAudio::get_plugin_parameters);
    ClassDB::bind_method(D_METHOD("get_plugin_parameter_text", "id", "place", "index", "param", "value"), &StudioSimAudio::get_plugin_parameter_text);
    ClassDB::bind_method(D_METHOD("set_vst3_search_paths", "paths"), &StudioSimAudio::set_vst3_search_paths);
    ClassDB::bind_method(D_METHOD("preset_extension", "plugin_id"), &StudioSimAudio::preset_extension);
    ClassDB::bind_method(D_METHOD("get_plugin_parameter", "id", "place", "index", "param"), &StudioSimAudio::get_plugin_parameter);
    ClassDB::bind_method(D_METHOD("set_plugin_parameter", "id", "place", "index", "param", "value"), &StudioSimAudio::set_plugin_parameter);
    ClassDB::bind_method(D_METHOD("notify_plugin_parameter", "id", "place", "index", "param"), &StudioSimAudio::notify_plugin_parameter);
    ClassDB::bind_method(D_METHOD("set_send", "id", "slot", "bus", "gain", "pre", "on"), &StudioSimAudio::set_send);
    ClassDB::bind_method(D_METHOD("set_master_automation", "volume", "which"), &StudioSimAudio::set_master_automation, DEFVAL("mix"));
    ClassDB::bind_method(D_METHOD("set_master_automation_read", "read", "which"), &StudioSimAudio::set_master_automation_read, DEFVAL("mix"));
    ClassDB::bind_method(D_METHOD("get_max_sends"), &StudioSimAudio::get_max_sends);
    ClassDB::bind_method(D_METHOD("get_audio_peaks", "path", "per_second"), &StudioSimAudio::get_audio_peaks);
    ClassDB::bind_method(D_METHOD("get_audio_seconds", "path"), &StudioSimAudio::get_audio_seconds);
    ClassDB::bind_method(D_METHOD("set_record_arm", "id", "armed"), &StudioSimAudio::set_record_arm);
    ClassDB::bind_method(D_METHOD("start_recording", "files", "from_step", "count_in_steps", "loop", "preroll_steps", "punch_out_step", "in_seconds"),
                         &StudioSimAudio::start_recording, DEFVAL(0.0), DEFVAL(false), DEFVAL(0.0), DEFVAL(-1.0), DEFVAL(-1.0));
    ClassDB::bind_method(D_METHOD("get_count_in"), &StudioSimAudio::get_count_in);
    ClassDB::bind_method(D_METHOD("stop_recording"), &StudioSimAudio::stop_recording);
    ClassDB::bind_method(D_METHOD("is_recording"), &StudioSimAudio::is_recording);
    ClassDB::bind_method(D_METHOD("take_recording"), &StudioSimAudio::take_recording);
    ClassDB::bind_method(D_METHOD("set_tempo", "bpm"), &StudioSimAudio::set_tempo);
    ClassDB::bind_method(D_METHOD("set_swing", "amount"), &StudioSimAudio::set_swing);
    ClassDB::bind_method(D_METHOD("set_click", "on"), &StudioSimAudio::set_click);
    ClassDB::bind_method(D_METHOD("set_click_volume", "gain"), &StudioSimAudio::set_click_volume);
    ClassDB::bind_method(D_METHOD("get_transport"), &StudioSimAudio::get_transport);
    ClassDB::bind_method(D_METHOD("get_drum_pieces", "kind"), &StudioSimAudio::get_drum_pieces, DEFVAL("drums"));
    ClassDB::bind_method(D_METHOD("get_drum_piece_name", "note", "kind"), &StudioSimAudio::get_drum_piece_name, DEFVAL("drums"));

    ClassDB::bind_method(D_METHOD("start_midi"), &StudioSimAudio::start_midi);
    ClassDB::bind_method(D_METHOD("poll_midi"), &StudioSimAudio::poll_midi);
    ClassDB::bind_method(D_METHOD("get_midi_devices"), &StudioSimAudio::get_midi_devices);
    ClassDB::bind_method(D_METHOD("set_midi_device_enabled", "name", "enabled"), &StudioSimAudio::set_midi_device_enabled);
    ClassDB::bind_method(D_METHOD("get_midi_event_count"), &StudioSimAudio::get_midi_event_count);
}

}  // namespace godot
