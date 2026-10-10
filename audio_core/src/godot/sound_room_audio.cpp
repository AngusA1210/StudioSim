#include "sound_room_audio.h"

#include <algorithm>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {
namespace {

sr::Vec3 vec(const Vector3& v) { return sr::Vec3{float(v.x), float(v.y), float(v.z)}; }
String str(const std::string& s) { return String::utf8(s.c_str()); }
std::string str(const String& s) { return std::string(s.utf8().get_data()); }

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

void SoundRoomAudio::set_source_direct_path(int id, const Vector3& via, float extra_length,
                                            const PackedFloat32Array& path_differences, bool blocked) {
    if (!engine_) return;
    float deltas[3] = {};
    const int count = int(std::min<int64_t>(path_differences.size(), 3));
    for (int i = 0; i < count; ++i) deltas[i] = path_differences[i];
    engine_->setSourceDirectPath(id, vec(via), extra_length, deltas, count, blocked);
}

void SoundRoomAudio::set_source_muted(int id, bool muted) { if (engine_) engine_->setSourceMuted(id, muted); }
void SoundRoomAudio::set_source_input_channel(int id, int channel) { if (engine_) engine_->setSourceInputChannel(id, channel); }

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
float SoundRoomAudio::get_source_level(int id) const { return engine_ ? engine_->sourceLevel(id) : 0.0f; }

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
void SoundRoomAudio::set_midi_target(int id) { if (engine_) engine_->setMidiTarget(id); }

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
    ClassDB::bind_method(D_METHOD("set_source_direct_path", "id", "via", "extra_length", "path_differences", "blocked"),
                         &SoundRoomAudio::set_source_direct_path);
    ClassDB::bind_method(D_METHOD("set_source_muted", "id", "muted"), &SoundRoomAudio::set_source_muted);
    ClassDB::bind_method(D_METHOD("set_source_input_channel", "id", "channel"), &SoundRoomAudio::set_source_input_channel);
    ClassDB::bind_method(D_METHOD("set_listener", "transform"), &SoundRoomAudio::set_listener);
    ClassDB::bind_method(D_METHOD("note_on", "id", "note", "velocity"), &SoundRoomAudio::note_on);
    ClassDB::bind_method(D_METHOD("note_off", "id", "note"), &SoundRoomAudio::note_off);
    ClassDB::bind_method(D_METHOD("all_notes_off", "id"), &SoundRoomAudio::all_notes_off);
    ClassDB::bind_method(D_METHOD("set_binaural", "on"), &SoundRoomAudio::set_binaural);
    ClassDB::bind_method(D_METHOD("set_reverb", "on"), &SoundRoomAudio::set_reverb);
    ClassDB::bind_method(D_METHOD("set_master_volume", "gain"), &SoundRoomAudio::set_master_volume);
    ClassDB::bind_method(D_METHOD("get_source_level", "id"), &SoundRoomAudio::get_source_level);
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
    ClassDB::bind_method(D_METHOD("set_midi_target", "id"), &SoundRoomAudio::set_midi_target);
    ClassDB::bind_method(D_METHOD("get_midi_devices"), &SoundRoomAudio::get_midi_devices);
    ClassDB::bind_method(D_METHOD("set_midi_device_enabled", "name", "enabled"), &SoundRoomAudio::set_midi_device_enabled);
    ClassDB::bind_method(D_METHOD("get_midi_event_count"), &SoundRoomAudio::get_midi_event_count);
}

}  // namespace godot
