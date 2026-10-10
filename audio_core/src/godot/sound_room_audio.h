#pragma once

// Godot's view of the audio core. GDScript drives it with positions and note events; every call returns
// immediately because it only queues a command for the audio thread. Opening devices is the exception:
// that happens on the calling thread and takes a moment.

#include <memory>

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
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

    // ── Playback engine and I/O ──────────────────────────────────────────────────────────────────────────
    // Opens the default output. silent = run the audio clock without a sound card (automated runs).
    bool start(bool silent);
    // Opens the devices described by `config`, closing whatever was open. Keys (all optional):
    //   silent: bool, output_device: String ("" = system default), input_enabled: bool,
    //   input_device: String ("" = system default), buffer_size: int, output_left: int, output_right: int
    // Returns false and leaves nothing open if a device can't be opened; see get_error().
    bool open_device(const Dictionary& config);
    Dictionary get_device_config() const;  // what is open now, same keys as above
    Array get_output_devices() const;      // [{name, is_default, channels}]
    Array get_input_devices() const;
    void set_output_channels(int left, int right);
    bool set_live_input(bool enabled);
    void stop();
    bool is_running() const;
    String get_error() const { return error_; }

    // ── The room ─────────────────────────────────────────────────────────────────────────────────────────
    // kind: "drums", "bass", "pad", "bells", "keys" or "live" (the audio input). Returns a source id, or -1.
    // Every kind but "live" can be played with note_on/note_off and given a pattern for the sequencer.
    int add_source(const String& kind, const Vector3& position, float gain, float reverb_send);
    void set_source_position(int id, const Vector3& position);
    // See AudioEngine::setSourceDirectPath: where the sound arrives from when walls are in the way.
    void set_source_direct_path(int id, const Vector3& via, float extra_length, const PackedFloat32Array& path_differences,
                                bool blocked);
    void set_source_muted(int id, bool muted);
    void set_source_input_channel(int id, int channel);  // live sources: 0-based hardware input, or -1 for all
    void set_listener(const Transform3D& transform);
    void note_on(int id, int note, float velocity);
    void note_off(int id, int note);
    void all_notes_off(int id);
    void set_binaural(bool on);
    void set_reverb(bool on);
    void set_master_volume(float gain);
    float get_source_level(int id) const;
    Dictionary get_stats() const;

    // ── The sequencer ────────────────────────────────────────────────────────────────────────────────────
    // Each source has a pattern of notes on a grid of sixteenths, which the clock plays round and round.
    // A note is {step, note, length (in steps), velocity (0-1), chance (0-1)}.
    void load_default_pattern(int id);  // the built-in groove's part for this kind of instrument
    Array get_pattern(int id) const;
    void set_pattern(int id, const Array& notes);
    // Adds a note, or replaces the one already at that step and pitch. False if the pattern is full.
    bool set_pattern_note(int id, int step, int note, float length, float velocity, float chance);
    void remove_pattern_note(int id, int step, int note);
    void set_pattern_steps(int id, int steps);  // 16, 32 or 64: how long before the pattern repeats
    int get_pattern_steps(int id) const;
    void set_source_loop(int id, bool on);      // whether the sequencer plays this source's pattern
    void set_sequencer_running(bool on);
    void set_tempo(float bpm);
    void set_swing(float amount);
    void set_click(bool on);                    // the metronome click
    void set_click_volume(float gain);
    Dictionary get_transport() const;           // {running, bpm, swing, click, click_volume, step}
    Array get_drum_pieces() const;              // [{name, note}]: the drum machine's pieces
    String get_drum_piece_name(int note) const; // which piece a note plays

    // ── MIDI ─────────────────────────────────────────────────────────────────────────────────────────────
    // Controllers go straight into the audio core and play `set_midi_target`'s source: the instrument the player
    // is at. With no target (-1) they play nothing.
    bool start_midi();
    void poll_midi();
    void set_midi_target(int id);
    Array get_midi_devices() const;  // [{name, enabled, events}]
    void set_midi_device_enabled(const String& name, bool enabled);
    int get_midi_event_count() const;

protected:
    static void _bind_methods();
    void _notification(int what);

private:
    bool ensureEngine();

    std::unique_ptr<sr::AudioEngine> engine_;
    String error_;
};

}  // namespace godot
