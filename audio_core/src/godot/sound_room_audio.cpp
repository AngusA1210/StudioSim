#include "sound_room_audio.h"

#include <algorithm>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {
namespace {

sr::Vec3 vec(const Vector3& v) { return sr::Vec3{float(v.x), float(v.y), float(v.z)}; }
String str(const std::string& s) { return String::utf8(s.c_str()); }
std::string str(const String& s) { return std::string(s.utf8().get_data()); }

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

SoundRoomAudio::SoundRoomAudio() = default;

SoundRoomAudio::~SoundRoomAudio() { stop(); }

void SoundRoomAudio::_notification(int what) {
    if (what == NOTIFICATION_PREDELETE) stop();
}

bool SoundRoomAudio::ensureEngine() {
    if (engine_) return true;
    auto engine = std::make_unique<sr::AudioEngine>();
    std::string err;
    if (!engine->init(&err)) {
        error_ = str(err);
        UtilityFunctions::push_error("SoundRoomAudio: ", error_);
        return false;
    }
    engine_ = std::move(engine);
    return true;
}

// ── Playback engine and I/O ────────────────────────────────────────────────────────────────────────────────
bool SoundRoomAudio::start(bool silent) {
    Dictionary config;
    config["silent"] = silent;
    return open_device(config);
}

bool SoundRoomAudio::open_device(const Dictionary& config) {
    if (!ensureEngine()) return false;
    sr::DeviceConfig c;
    c.mode = bool(config.get("silent", false)) ? sr::DeviceMode::Null : sr::DeviceMode::Hardware;
    c.output_device = str(String(config.get("output_device", "")));
    c.input_enabled = bool(config.get("input_enabled", false));
    c.input_device = str(String(config.get("input_device", "")));
    c.buffer_size = int(config.get("buffer_size", 128));
    c.output_left = int(config.get("output_left", 0));
    c.output_right = int(config.get("output_right", 1));
    std::string err;
    if (engine_->openDevice(c, &err)) {
        error_ = String();
        return true;
    }
    error_ = str(err);
    return false;
}

Dictionary SoundRoomAudio::get_device_config() const {
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
    return d;
}

Array SoundRoomAudio::get_output_devices() const { return deviceList(sr::AudioEngine::outputDevices()); }
Array SoundRoomAudio::get_input_devices() const { return deviceList(sr::AudioEngine::inputDevices()); }

void SoundRoomAudio::set_output_channels(int left, int right) { if (engine_) engine_->setOutputChannels(left, right); }

bool SoundRoomAudio::set_live_input(bool enabled) {
    if (!engine_) return false;
    std::string err;
    if (engine_->setLiveInput(enabled, &err)) return true;
    error_ = str(err);
    return false;
}

void SoundRoomAudio::stop() { engine_.reset(); }

bool SoundRoomAudio::is_running() const { return engine_ && engine_->stats().device_running; }

// ── The room ───────────────────────────────────────────────────────────────────────────────────────────────
int SoundRoomAudio::add_source(const String& kind, const Vector3& position, float gain, float reverb_send) {
    if (!ensureEngine()) return -1;
    sr::InstrumentKind k;
    if (kind == "drums") k = sr::InstrumentKind::Drums;
    else if (kind == "bass") k = sr::InstrumentKind::Bass;
    else if (kind == "pad") k = sr::InstrumentKind::Pad;
    else if (kind == "bells") k = sr::InstrumentKind::Bells;
    else if (kind == "keys") k = sr::InstrumentKind::Keys;
    else if (kind == "live") k = sr::InstrumentKind::Live;
    else if (kind == "guitar_combo") k = sr::InstrumentKind::GuitarCombo;
    else if (kind == "guitar_stack") k = sr::InstrumentKind::GuitarStack;
    else if (kind == "bass_combo") k = sr::InstrumentKind::BassCombo;
    else if (kind == "bass_stack") k = sr::InstrumentKind::BassStack;
    else {
        UtilityFunctions::push_error("SoundRoomAudio: unknown instrument kind ", kind);
        return -1;
    }
    return engine_->addSource(k, vec(position), gain, reverb_send);
}

bool SoundRoomAudio::remove_source(int id) { return engine_ && engine_->removeSource(id); }
int SoundRoomAudio::get_source_count() const { return engine_ ? engine_->sourceCount() : 0; }
int SoundRoomAudio::get_max_sources() const { return sr::AudioEngine::kMaxSources; }

void SoundRoomAudio::set_source_position(int id, const Vector3& p) { if (engine_) engine_->setSourcePosition(id, vec(p)); }

bool SoundRoomAudio::is_source_blocked(int id) const { return engine_ && engine_->sourceBlocked(id); }
void SoundRoomAudio::set_source_gain(int id, float gain) { if (engine_) engine_->setSourceGain(id, gain); }

void SoundRoomAudio::set_room(const Vector3& size, const Array& walls) {
    if (!ensureEngine()) return;
    std::vector<sr::Wall> list;
    for (int64_t i = 0; i < walls.size(); ++i) {
        const Dictionary wall = walls[i];
        const Vector2 a = wall.get("a", Vector2()), b = wall.get("b", Vector2());
        list.push_back({float(a.x), float(a.y), float(b.x), float(b.y), float(wall.get("thickness", 0.3)), float(wall.get("height", 3.0))});
    }
    engine_->setRoom(float(size.x), float(size.y), float(size.z), list);
}

bool SoundRoomAudio::is_room_settled() { return engine_ && engine_->roomSettled(); }
float SoundRoomAudio::get_room_decay() const { return engine_ ? engine_->roomDecaySeconds() : 0.0f; }

void SoundRoomAudio::set_source_muted(int id, bool muted) { if (engine_) engine_->setSourceMuted(id, muted); }
void SoundRoomAudio::set_source_input_channel(int id, int channel) { if (engine_) engine_->setSourceInputChannel(id, channel); }
void SoundRoomAudio::set_source_input(int id, bool on) { if (engine_) engine_->setSourceInput(id, on); }

void SoundRoomAudio::set_amp_control(int id, const String& control, float value) {
    static const char* const kNames[sr::kAmpControls] = {"gain", "bass", "mid", "treble", "presence", "master"};
    for (int c = 0; c < sr::kAmpControls; ++c)
        if (control == kNames[c] && engine_) engine_->setAmpControl(id, sr::AmpControl(c), value);
}

bool SoundRoomAudio::looper(int id, const String& action) {
    static const char* const kNames[] = {"press", "stop", "play", "undo", "redo", "clear"};
    for (int a = 0; a < 6; ++a)
        if (action == kNames[a]) return engine_ && engine_->looperAction(id, sr::Looper::Action(a));
    return false;
}


Dictionary SoundRoomAudio::get_looper(int id) const {
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

int SoundRoomAudio::add_pedal(int id, const String& kind, int at) {
    for (int k = 0; k < sr::kPedalKinds; ++k)
        if (kind == kPedalNames[k]) return engine_ ? engine_->addPedal(id, sr::PedalKind(k), at) : -1;
    return -1;
}
bool SoundRoomAudio::remove_pedal(int id, int index) { return engine_ && engine_->removePedal(id, index); }
bool SoundRoomAudio::move_pedal(int id, int from, int to) { return engine_ && engine_->movePedal(id, from, to); }
void SoundRoomAudio::set_pedal_on(int id, int index, bool on) { if (engine_) engine_->setPedalOn(id, index, on); }
void SoundRoomAudio::set_pedal_control(int id, int index, int control, float value) {
    if (engine_) engine_->setPedalControl(id, index, control, value);
}
int SoundRoomAudio::get_max_pedals() const { return sr::kMaxPedals; }

Array SoundRoomAudio::get_pedals(int id) const {
    Array out;
    if (!engine_) return out;
    for (const sr::PedalStatus& p : engine_->pedals(id)) {
        Dictionary d;
        d["kind"] = String(kPedalNames[int(p.kind)]);
        d["on"] = p.on;
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

Dictionary SoundRoomAudio::get_tuner(int id) const {
    Dictionary d;
    const sr::TunerReading r = engine_ ? engine_->tuner(id) : sr::TunerReading{};
    d["listening"] = r.listening;
    d["pitched"] = r.pitched;
    d["frequency"] = r.frequency;
    d["note"] = r.note;
    d["cents"] = r.cents;
    return d;
}

Array SoundRoomAudio::get_plugins() const {
    Array out;
    for (const sr::PluginDescription& p : sr::AudioEngine::effectPlugins()) {
        Dictionary d;
        d["id"] = str(p.id);
        d["name"] = str(p.name);
        d["maker"] = str(p.maker);
        d["category"] = str(p.category);
        out.push_back(d);
    }
    return out;
}

bool SoundRoomAudio::load_pedal_plugin(int id, int index, const String& plugin_id) {
    std::string err;
    if (engine_ && engine_->loadPedalPlugin(id, index, str(plugin_id), &err)) return true;
    error_ = str(err.empty() ? std::string("the audio engine isn't running") : err);
    return false;
}

bool SoundRoomAudio::show_plugin_editor(int id, int index, bool show, const String& title) {
    return engine_ && engine_->showPluginEditor(id, index, show, str(title));
}

Array SoundRoomAudio::get_inserts(int id) const {
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

bool SoundRoomAudio::set_insert(int id, int slot, const String& plugin_id) {
    std::string err;
    if (engine_ && engine_->setInsert(id, slot, str(plugin_id), &err)) return true;
    error_ = str(err.empty() ? std::string("the audio engine isn't running") : err);
    return false;
}
bool SoundRoomAudio::clear_insert(int id, int slot) { return engine_ && engine_->clearInsert(id, slot); }
void SoundRoomAudio::set_insert_on(int id, int slot, bool on) { if (engine_) engine_->setInsertOn(id, slot, on); }
bool SoundRoomAudio::show_insert_editor(int id, int slot, bool show, const String& title) {
    return engine_ && engine_->showInsertEditor(id, slot, show, str(title));
}
int SoundRoomAudio::get_max_inserts() const { return sr::AudioEngine::kMaxInserts; }

void SoundRoomAudio::set_listener(const Transform3D& t) {
    if (!engine_) return;
    // Godot and Steam Audio share conventions: -Z is ahead, +Y is up.
    engine_->setListener(vec(t.origin), vec(-t.basis.get_column(2).normalized()), vec(t.basis.get_column(1).normalized()));
}

void SoundRoomAudio::note_on(int id, int note, float velocity) { if (engine_) engine_->noteOn(id, note, velocity); }
void SoundRoomAudio::note_off(int id, int note) { if (engine_) engine_->noteOff(id, note); }
void SoundRoomAudio::all_notes_off(int id) { if (engine_) engine_->allNotesOff(id); }
void SoundRoomAudio::set_binaural(bool on) { if (engine_) engine_->setBinaural(on); }
void SoundRoomAudio::set_reverb(bool on) { if (engine_) engine_->setReverb(on); }
void SoundRoomAudio::set_master_volume(float gain) { if (engine_) engine_->setMasterVolume(gain); }
void SoundRoomAudio::set_distance_falloff(float db_per_doubling) { if (engine_) engine_->setDistanceFalloff(db_per_doubling); }
void SoundRoomAudio::set_limiter(bool on) { if (engine_) engine_->setLimiter(on); }

Dictionary SoundRoomAudio::read_meter() {
    Dictionary d;
    if (!engine_) return d;
    const sr::MeterReading m = engine_->readMeter();
    d["peak_l"] = m.peak_l;
    d["peak_r"] = m.peak_r;
    d["rms_l"] = m.rms_l;
    d["rms_r"] = m.rms_r;
    d["limiter_gain"] = m.limiter_gain;
    d["clipped"] = int64_t(m.clipped);
    return d;
}
void SoundRoomAudio::set_source_volume(int id, float gain) { if (engine_) engine_->setSourceVolume(id, gain); }
float SoundRoomAudio::get_source_level(int id, bool pre_fader) const { return engine_ ? engine_->sourceLevel(id, pre_fader) : 0.0f; }
float SoundRoomAudio::get_source_peak(int id, bool pre_fader) { return engine_ ? engine_->sourcePeak(id, pre_fader) : 0.0f; }

Dictionary SoundRoomAudio::get_stats() const {
    Dictionary d;
    if (!engine_) return d;
    const sr::EngineStats s = engine_->stats();
    d["device_running"] = s.device_running;
    d["backend"] = str(s.backend);
    d["output_device"] = str(s.output_device);
    d["output_channels"] = s.output_channels;
    d["sample_rate"] = s.sample_rate;
    d["block_size"] = s.block_size;
    d["device_period"] = s.device_period;
    d["buffer_ms"] = s.buffer_ms;
    d["device_ms"] = s.device_ms;
    d["binaural_ms"] = s.binaural_ms;
    d["output_latency_ms"] = s.output_latency_ms;
    d["live_input"] = s.live_input;
    d["input_device"] = str(s.input_device);
    d["input_channels"] = s.input_channels;
    d["input_latency_ms"] = s.input_latency_ms;
    d["cpu_load"] = s.cpu_load;
    d["blocks"] = int64_t(s.blocks);
    return d;
}

// ── The sequencer ──────────────────────────────────────────────────────────────────────────────────────────
void SoundRoomAudio::load_default_pattern(int id) { if (engine_) engine_->loadDefaultPattern(id); }

Array SoundRoomAudio::get_pattern(int id) const {
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

void SoundRoomAudio::set_pattern(int id, const Array& notes) {
    if (!engine_) return;
    std::vector<sr::PatternNote> pattern;
    for (int64_t i = 0; i < notes.size(); ++i) {
        const Dictionary note = notes[i];
        pattern.push_back({int(note.get("step", 0)), int(note.get("note", 60)), float(note.get("length", 1.0)),
                           float(note.get("velocity", 0.8)), float(note.get("chance", 1.0))});
    }
    engine_->setPattern(id, pattern);
}

bool SoundRoomAudio::set_pattern_note(int id, int step, int note, float length, float velocity, float chance) {
    return engine_ && engine_->setPatternNote(id, {step, note, length, velocity, chance});
}

void SoundRoomAudio::remove_pattern_note(int id, int step, int note) { if (engine_) engine_->removePatternNote(id, step, note); }
void SoundRoomAudio::set_pattern_steps(int id, int steps) { if (engine_) engine_->setPatternSteps(id, steps); }
int SoundRoomAudio::get_pattern_steps(int id) const { return engine_ ? engine_->patternSteps(id) : 0; }
void SoundRoomAudio::set_source_loop(int id, bool on) { if (engine_) engine_->setSourceLoop(id, on); }
void SoundRoomAudio::set_sequencer_running(bool on) { if (engine_) engine_->setSequencerRunning(on); }
void SoundRoomAudio::set_tempo(float bpm) { if (engine_) engine_->setTempo(bpm); }
void SoundRoomAudio::set_swing(float amount) { if (engine_) engine_->setSwing(amount); }
void SoundRoomAudio::set_click(bool on) { if (engine_) engine_->setClick(on); }
void SoundRoomAudio::set_click_volume(float gain) { if (engine_) engine_->setClickVolume(gain); }

Dictionary SoundRoomAudio::get_transport() const {
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

Array SoundRoomAudio::get_drum_pieces() const {
    Array out;
    for (int piece = 0; piece < sr::Drums::kPieces; ++piece) {
        Dictionary entry;
        entry["name"] = String(sr::Drums::pieceName(sr::Drums::Piece(piece)));
        entry["note"] = sr::Drums::noteFor(sr::Drums::Piece(piece));
        out.push_back(entry);
    }
    return out;
}

String SoundRoomAudio::get_drum_piece_name(int note) const { return String(sr::Drums::pieceName(sr::Drums::pieceFor(note))); }

// ── MIDI ───────────────────────────────────────────────────────────────────────────────────────────────────
bool SoundRoomAudio::start_midi() {
    if (!ensureEngine()) return false;
    std::string err;
    if (engine_->startMidi(&err)) return true;
    error_ = str(err);
    return false;
}

void SoundRoomAudio::poll_midi() { if (engine_) engine_->pollMidi(); }

Array SoundRoomAudio::get_midi_devices() const {
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

void SoundRoomAudio::set_midi_device_enabled(const String& name, bool enabled) {
    if (ensureEngine()) engine_->setMidiDeviceEnabled(str(name), enabled);
}

int SoundRoomAudio::get_midi_event_count() const { return engine_ ? int(engine_->midiEventCount()) : 0; }

void SoundRoomAudio::_bind_methods() {
    ClassDB::bind_method(D_METHOD("start", "silent"), &SoundRoomAudio::start, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("open_device", "config"), &SoundRoomAudio::open_device);
    ClassDB::bind_method(D_METHOD("get_device_config"), &SoundRoomAudio::get_device_config);
    ClassDB::bind_method(D_METHOD("get_output_devices"), &SoundRoomAudio::get_output_devices);
    ClassDB::bind_method(D_METHOD("get_input_devices"), &SoundRoomAudio::get_input_devices);
    ClassDB::bind_method(D_METHOD("set_output_channels", "left", "right"), &SoundRoomAudio::set_output_channels);
    ClassDB::bind_method(D_METHOD("set_live_input", "enabled"), &SoundRoomAudio::set_live_input);
    ClassDB::bind_method(D_METHOD("stop"), &SoundRoomAudio::stop);
    ClassDB::bind_method(D_METHOD("is_running"), &SoundRoomAudio::is_running);
    ClassDB::bind_method(D_METHOD("get_error"), &SoundRoomAudio::get_error);

    ClassDB::bind_method(D_METHOD("add_source", "kind", "position", "gain", "reverb_send"), &SoundRoomAudio::add_source);
    ClassDB::bind_method(D_METHOD("remove_source", "id"), &SoundRoomAudio::remove_source);
    ClassDB::bind_method(D_METHOD("get_source_count"), &SoundRoomAudio::get_source_count);
    ClassDB::bind_method(D_METHOD("get_max_sources"), &SoundRoomAudio::get_max_sources);
    ClassDB::bind_method(D_METHOD("set_source_position", "id", "position"), &SoundRoomAudio::set_source_position);
    ClassDB::bind_method(D_METHOD("is_source_blocked", "id"), &SoundRoomAudio::is_source_blocked);
    ClassDB::bind_method(D_METHOD("set_room", "size", "walls"), &SoundRoomAudio::set_room);
    ClassDB::bind_method(D_METHOD("is_room_settled"), &SoundRoomAudio::is_room_settled);
    ClassDB::bind_method(D_METHOD("get_room_decay"), &SoundRoomAudio::get_room_decay);
    ClassDB::bind_method(D_METHOD("set_source_muted", "id", "muted"), &SoundRoomAudio::set_source_muted);
    ClassDB::bind_method(D_METHOD("set_source_input_channel", "id", "channel"), &SoundRoomAudio::set_source_input_channel);
    ClassDB::bind_method(D_METHOD("set_source_input", "id", "on"), &SoundRoomAudio::set_source_input);
    ClassDB::bind_method(D_METHOD("set_amp_control", "id", "control", "value"), &SoundRoomAudio::set_amp_control);
    ClassDB::bind_method(D_METHOD("looper", "id", "action"), &SoundRoomAudio::looper);
    ClassDB::bind_method(D_METHOD("get_looper", "id"), &SoundRoomAudio::get_looper);
    ClassDB::bind_method(D_METHOD("add_pedal", "id", "kind", "at"), &SoundRoomAudio::add_pedal);
    ClassDB::bind_method(D_METHOD("remove_pedal", "id", "index"), &SoundRoomAudio::remove_pedal);
    ClassDB::bind_method(D_METHOD("move_pedal", "id", "from", "to"), &SoundRoomAudio::move_pedal);
    ClassDB::bind_method(D_METHOD("set_pedal_on", "id", "index", "on"), &SoundRoomAudio::set_pedal_on);
    ClassDB::bind_method(D_METHOD("set_pedal_control", "id", "index", "control", "value"), &SoundRoomAudio::set_pedal_control);
    ClassDB::bind_method(D_METHOD("get_pedals", "id"), &SoundRoomAudio::get_pedals);
    ClassDB::bind_method(D_METHOD("get_tuner", "id"), &SoundRoomAudio::get_tuner);
    ClassDB::bind_method(D_METHOD("get_max_pedals"), &SoundRoomAudio::get_max_pedals);
    ClassDB::bind_method(D_METHOD("get_plugins"), &SoundRoomAudio::get_plugins);
    ClassDB::bind_method(D_METHOD("load_pedal_plugin", "id", "index", "plugin_id"), &SoundRoomAudio::load_pedal_plugin);
    ClassDB::bind_method(D_METHOD("show_plugin_editor", "id", "index", "show", "title"), &SoundRoomAudio::show_plugin_editor);
    ClassDB::bind_method(D_METHOD("get_inserts", "id"), &SoundRoomAudio::get_inserts);
    ClassDB::bind_method(D_METHOD("set_insert", "id", "slot", "plugin_id"), &SoundRoomAudio::set_insert);
    ClassDB::bind_method(D_METHOD("clear_insert", "id", "slot"), &SoundRoomAudio::clear_insert);
    ClassDB::bind_method(D_METHOD("set_insert_on", "id", "slot", "on"), &SoundRoomAudio::set_insert_on);
    ClassDB::bind_method(D_METHOD("show_insert_editor", "id", "slot", "show", "title"), &SoundRoomAudio::show_insert_editor);
    ClassDB::bind_method(D_METHOD("get_max_inserts"), &SoundRoomAudio::get_max_inserts);
    ClassDB::bind_method(D_METHOD("set_listener", "transform"), &SoundRoomAudio::set_listener);
    ClassDB::bind_method(D_METHOD("note_on", "id", "note", "velocity"), &SoundRoomAudio::note_on);
    ClassDB::bind_method(D_METHOD("note_off", "id", "note"), &SoundRoomAudio::note_off);
    ClassDB::bind_method(D_METHOD("all_notes_off", "id"), &SoundRoomAudio::all_notes_off);
    ClassDB::bind_method(D_METHOD("set_binaural", "on"), &SoundRoomAudio::set_binaural);
    ClassDB::bind_method(D_METHOD("set_reverb", "on"), &SoundRoomAudio::set_reverb);
    ClassDB::bind_method(D_METHOD("set_master_volume", "gain"), &SoundRoomAudio::set_master_volume);
    ClassDB::bind_method(D_METHOD("set_source_gain", "id", "gain"), &SoundRoomAudio::set_source_gain);
    ClassDB::bind_method(D_METHOD("set_distance_falloff", "db_per_doubling"), &SoundRoomAudio::set_distance_falloff);
    ClassDB::bind_method(D_METHOD("set_limiter", "on"), &SoundRoomAudio::set_limiter);
    ClassDB::bind_method(D_METHOD("read_meter"), &SoundRoomAudio::read_meter);
    ClassDB::bind_method(D_METHOD("get_source_level", "id", "pre_fader"), &SoundRoomAudio::get_source_level, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("get_source_peak", "id", "pre_fader"), &SoundRoomAudio::get_source_peak, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("set_source_volume", "id", "gain"), &SoundRoomAudio::set_source_volume);
    ClassDB::bind_method(D_METHOD("get_stats"), &SoundRoomAudio::get_stats);

    ClassDB::bind_method(D_METHOD("load_default_pattern", "id"), &SoundRoomAudio::load_default_pattern);
    ClassDB::bind_method(D_METHOD("get_pattern", "id"), &SoundRoomAudio::get_pattern);
    ClassDB::bind_method(D_METHOD("set_pattern", "id", "notes"), &SoundRoomAudio::set_pattern);
    ClassDB::bind_method(D_METHOD("set_pattern_note", "id", "step", "note", "length", "velocity", "chance"),
                         &SoundRoomAudio::set_pattern_note);
    ClassDB::bind_method(D_METHOD("remove_pattern_note", "id", "step", "note"), &SoundRoomAudio::remove_pattern_note);
    ClassDB::bind_method(D_METHOD("set_pattern_steps", "id", "steps"), &SoundRoomAudio::set_pattern_steps);
    ClassDB::bind_method(D_METHOD("get_pattern_steps", "id"), &SoundRoomAudio::get_pattern_steps);
    ClassDB::bind_method(D_METHOD("set_source_loop", "id", "on"), &SoundRoomAudio::set_source_loop);
    ClassDB::bind_method(D_METHOD("set_sequencer_running", "on"), &SoundRoomAudio::set_sequencer_running);
    ClassDB::bind_method(D_METHOD("set_tempo", "bpm"), &SoundRoomAudio::set_tempo);
    ClassDB::bind_method(D_METHOD("set_swing", "amount"), &SoundRoomAudio::set_swing);
    ClassDB::bind_method(D_METHOD("set_click", "on"), &SoundRoomAudio::set_click);
    ClassDB::bind_method(D_METHOD("set_click_volume", "gain"), &SoundRoomAudio::set_click_volume);
    ClassDB::bind_method(D_METHOD("get_transport"), &SoundRoomAudio::get_transport);
    ClassDB::bind_method(D_METHOD("get_drum_pieces"), &SoundRoomAudio::get_drum_pieces);
    ClassDB::bind_method(D_METHOD("get_drum_piece_name", "note"), &SoundRoomAudio::get_drum_piece_name);

    ClassDB::bind_method(D_METHOD("start_midi"), &SoundRoomAudio::start_midi);
    ClassDB::bind_method(D_METHOD("poll_midi"), &SoundRoomAudio::poll_midi);
    ClassDB::bind_method(D_METHOD("get_midi_devices"), &SoundRoomAudio::get_midi_devices);
    ClassDB::bind_method(D_METHOD("set_midi_device_enabled", "name", "enabled"), &SoundRoomAudio::set_midi_device_enabled);
    ClassDB::bind_method(D_METHOD("get_midi_event_count"), &SoundRoomAudio::get_midi_event_count);
}

}  // namespace godot
