#include "sound_room_audio.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {
namespace {

sr::Vec3 vec(const Vector3& v) { return sr::Vec3{float(v.x), float(v.y), float(v.z)}; }

}  // namespace

SoundRoomAudio::SoundRoomAudio() = default;

SoundRoomAudio::~SoundRoomAudio() { stop(); }

void SoundRoomAudio::_notification(int what) {
    if (what == NOTIFICATION_PREDELETE) stop();
}

bool SoundRoomAudio::start(bool silent) {
    if (engine_) return true;
    sr::EngineConfig config;
    if (!silent) config.sample_rate = sr::AudioEngine::defaultOutputSampleRate();
    auto engine = std::make_unique<sr::AudioEngine>(config);
    std::string err;
    if (!engine->init(&err) ||
        !engine->startDevice(silent ? sr::DeviceMode::Null : sr::DeviceMode::Hardware, &err)) {
        error_ = String(err.c_str());
        UtilityFunctions::push_error("SoundRoomAudio: ", error_);
        return false;
    }
    engine_ = std::move(engine);
    error_ = String();
    return true;
}

void SoundRoomAudio::stop() { engine_.reset(); }

bool SoundRoomAudio::is_running() const { return engine_ != nullptr; }

int SoundRoomAudio::add_source(const String& kind, const Vector3& position, float gain, float reverb_send) {
    if (!engine_) return -1;
    sr::InstrumentKind k;
    if (kind == "drums") k = sr::InstrumentKind::Drums;
    else if (kind == "bass") k = sr::InstrumentKind::Bass;
    else if (kind == "pad") k = sr::InstrumentKind::Pad;
    else if (kind == "bells") k = sr::InstrumentKind::Bells;
    else if (kind == "keys") k = sr::InstrumentKind::Keys;
    else {
        UtilityFunctions::push_error("SoundRoomAudio: unknown instrument kind ", kind);
        return -1;
    }
    return engine_->addSource(k, vec(position), gain, reverb_send);
}

void SoundRoomAudio::set_source_position(int id, const Vector3& p) { if (engine_) engine_->setSourcePosition(id, vec(p)); }
void SoundRoomAudio::set_source_muted(int id, bool muted) { if (engine_) engine_->setSourceMuted(id, muted); }
void SoundRoomAudio::set_source_visibility(int id, float visible) { if (engine_) engine_->setSourceVisibility(id, visible); }

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
float SoundRoomAudio::get_source_level(int id) const { return engine_ ? engine_->sourceLevel(id) : 0.0f; }

Dictionary SoundRoomAudio::get_stats() const {
    Dictionary d;
    if (!engine_) return d;
    const sr::EngineStats s = engine_->stats();
    d["backend"] = String(s.backend.c_str());
    d["sample_rate"] = s.sample_rate;
    d["block_size"] = s.block_size;
    d["device_period"] = s.device_period;
    d["buffer_ms"] = s.buffer_ms;
    d["device_ms"] = s.device_ms;
    d["output_latency_ms"] = s.output_latency_ms;
    d["cpu_load"] = s.cpu_load;
    d["blocks"] = int64_t(s.blocks);
    return d;
}

void SoundRoomAudio::_bind_methods() {
    ClassDB::bind_method(D_METHOD("start", "silent"), &SoundRoomAudio::start, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("stop"), &SoundRoomAudio::stop);
    ClassDB::bind_method(D_METHOD("is_running"), &SoundRoomAudio::is_running);
    ClassDB::bind_method(D_METHOD("get_error"), &SoundRoomAudio::get_error);
    ClassDB::bind_method(D_METHOD("add_source", "kind", "position", "gain", "reverb_send"), &SoundRoomAudio::add_source);
    ClassDB::bind_method(D_METHOD("set_source_position", "id", "position"), &SoundRoomAudio::set_source_position);
    ClassDB::bind_method(D_METHOD("set_source_muted", "id", "muted"), &SoundRoomAudio::set_source_muted);
    ClassDB::bind_method(D_METHOD("set_source_visibility", "id", "visible"), &SoundRoomAudio::set_source_visibility);
    ClassDB::bind_method(D_METHOD("set_listener", "transform"), &SoundRoomAudio::set_listener);
    ClassDB::bind_method(D_METHOD("note_on", "id", "note", "velocity"), &SoundRoomAudio::note_on);
    ClassDB::bind_method(D_METHOD("note_off", "id", "note"), &SoundRoomAudio::note_off);
    ClassDB::bind_method(D_METHOD("all_notes_off", "id"), &SoundRoomAudio::all_notes_off);
    ClassDB::bind_method(D_METHOD("set_binaural", "on"), &SoundRoomAudio::set_binaural);
    ClassDB::bind_method(D_METHOD("set_reverb", "on"), &SoundRoomAudio::set_reverb);
    ClassDB::bind_method(D_METHOD("get_source_level", "id"), &SoundRoomAudio::get_source_level);
    ClassDB::bind_method(D_METHOD("get_stats"), &SoundRoomAudio::get_stats);
}

}  // namespace godot
