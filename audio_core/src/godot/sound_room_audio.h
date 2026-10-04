#pragma once

// Godot's view of the audio core. GDScript drives it with positions and note events; every call returns
// immediately because it only queues a command for the audio thread.

#include <memory>

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "engine.h"

namespace godot {

class SoundRoomAudio : public Node {
    GDCLASS(SoundRoomAudio, Node)

public:
    SoundRoomAudio();
    ~SoundRoomAudio() override;

    // silent = run the audio clock without opening a sound card (automated runs)
    bool start(bool silent);
    void stop();
    bool is_running() const;
    String get_error() const { return error_; }

    // kind: "drums", "bass", "pad", "bells", "keys" or "live" (the audio input). Returns a source id, or -1.
    int add_source(const String& kind, const Vector3& position, float gain, float reverb_send);
    void set_source_position(int id, const Vector3& position);
    // See AudioEngine::setSourceDirectPath: where the sound arrives from when walls are in the way.
    void set_source_direct_path(int id, const Vector3& via, float extra_length, const PackedFloat32Array& path_differences,
                                bool blocked);
    void set_source_muted(int id, bool muted);
    void set_listener(const Transform3D& transform);
    void note_on(int id, int note, float velocity);
    void note_off(int id, int note);
    void all_notes_off(int id);
    void set_binaural(bool on);
    void set_reverb(bool on);
    float get_source_level(int id) const;
    Dictionary get_stats() const;

    // MIDI controllers go straight into the audio core and play `set_midi_target`'s source (default: the Keys).
    bool start_midi();
    void poll_midi();
    void set_midi_target(int id);
    PackedStringArray get_midi_devices() const;
    int get_midi_event_count() const;

    // Opens or closes the audio input (microphone / interface) feeding "live" sources.
    bool set_live_input(bool enabled);

protected:
    static void _bind_methods();
    void _notification(int what);

private:
    std::unique_ptr<sr::AudioEngine> engine_;
    String error_;
};

}  // namespace godot
