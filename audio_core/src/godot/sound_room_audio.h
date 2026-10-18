#pragma once

// Godot's view of the audio core. GDScript drives it with positions and note events; every call returns
// immediately because it only queues a command for the audio thread. Opening devices is the exception:
// that happens on the calling thread and takes a moment.

#include <memory>

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
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
    // kind: "drums", "bass", "pad", "bells", "keys", "live" (the Speaker), or an amp: "guitar_combo",
    // "guitar_stack", "bass_combo", "bass_stack". Returns a source id, or -1.
    // Every kind but "live" can be played with note_on/note_off and given a pattern for the sequencer.
    int add_source(const String& kind, const Vector3& position, float gain, float reverb_send);
    bool remove_source(int id);    // fades it out and frees its id for reuse
    int get_source_count() const;
    int get_max_sources() const;
    void set_source_position(int id, const Vector3& position);
    bool is_source_blocked(int id) const;  // a wall stands between it and the listener
    void set_source_gain(int id, float gain);  // its level within the reference distance; 1 = as it was added
    void set_source_volume(int id, float gain);  // its own volume, after its inserts and before its fader (a Speaker's)
    // The room's inside size (width, height, depth) in metres and the walls standing in it, each
    // {a: Vector2, b: Vector2, thickness: float, height: float} with a and b on the floor plan (x, z).
    // The audio core works out how sound gets round the walls, and how long and loudly a room that size rings.
    void set_room(const Vector3& size, const Array& walls);
    bool is_room_settled();          // false while the reverb is still changing over to a new size
    float get_room_decay() const;    // the reverb time (RT60) that goes with the room's size, in seconds
    void set_source_muted(int id, bool muted);
    void set_source_input_channel(int id, int channel);  // live sources: 0-based hardware input, or -1 for all
    // Whether a source takes input: an instrument plays what MIDI controllers send, a live source plays its
    // hardware input. Every source starts with its input off.
    void set_source_input(int id, bool on);

    // ── Amps ─────────────────────────────────────────────────────────────────────────────────────────────
    // control: "gain", "bass", "mid", "treble", "presence" or "master"; value 0 to 10 as on the panel.
    void set_amp_control(int id, const String& control, float value);
    // Which head and cabinet an amp uses, and whether each is in use.
    // head: "clean", "crunch", "high_gain", "bass_round" or "bass_punch";
    // cabinet: "1x12", "2x12", "4x12", "1x15", "4x10" or "8x10".
    void set_amp_head(int id, const String& head, bool on);
    void set_amp_cabinet(int id, const String& cabinet, bool on);
    // The loop pedal on an amp's board (a "looper" pedal; its controls are its level, Sync, and Overdub after
    // recording). action: "press" (the footswitch: record, play, overdub), "stop", "play", "undo", "redo" or "clear".
    // False if the amp has no loop pedal.
    bool looper(int id, const String& action);
    // {state: "none" (no loop pedal)|"empty"|"waiting"|"recording"|"playing"|"overdubbing"|"stopped", length, position,
    //  capacity (seconds), can_undo, can_redo}
    Dictionary get_looper(int id) const;
    // The effect pedals in front of an amp, numbered in the order the signal passes through them (the loop pedal comes
    // after them all). kind: "tuner", "gate", "compressor", "overdrive", "fuzz", "envelope_filter", "chorus", "phaser",
    // "tremolo", "delay", "reverb", "looper" or "plugin". Returns where it went, or -1 (not an amp, its board is full,
    // or a second loop pedal).
    int add_pedal(int id, const String& kind, int at);
    bool remove_pedal(int id, int index);
    bool move_pedal(int id, int from, int to);
    // A second of a pedal (a Plug-in pedal's plug-in and its settings too) on this amp's board or another's, at `at`
    // (-1: the end). Where it went, or -1, with the reason in get_error().
    int copy_pedal(int from_id, int index, int to_id, int at);
    void set_pedal_on(int id, int index, bool on);
    void set_pedal_control(int id, int index, int control, float value);  // knobs 0 to 10, switches 0 or 1
    // [{kind, on, controls: [5 numbers], plugin_id, plugin_name, plugin_maker, editor_open}]
    Array get_pedals(int id) const;
    Dictionary get_tuner(int id) const;  // {listening, pitched, frequency, note (MIDI), cents}: the amp's first tuner
    int get_max_pedals() const;
    // The effect plug-ins installed on this computer (Audio Units on macOS): [{id, name, maker, category}], the
    // category being what kind of effect it seems to be ("Reverb", "Amps & cabinets"...).
    Array get_plugins() const;
    // Plug-in instruments (a source of kind "plugin_synth"): the instrument plug-ins installed, as get_plugins lists
    // effects (category "Synths", "Pianos & keys", "Drums & percussion", "Samplers"...); loading one into such a source,
    // with these settings if any are given (false with the reason in get_error()); what it holds:
    // {plugin_id, plugin_name, plugin_maker, editor_open}; and its window.
    Array get_instrument_plugins() const;
    bool set_instrument_plugin(int id, const String& plugin_id, const PackedByteArray& state);
    Dictionary get_instrument_plugin(int id) const;
    bool show_instrument_editor(int id, bool show, const String& title);
    // Moves that window to the middle of the game's, its bottom `above_bottom` of the way up it (0 to 1).
    void place_instrument_editor(int id, float above_bottom);
    // Loads one into a Plug-in pedal, with these settings if any are given; false with the reason in get_error().
    bool load_pedal_plugin(int id, int index, const String& plugin_id, const PackedByteArray& state);
    bool show_plugin_editor(int id, int index, bool show, const String& title);  // the plug-in's own window
    // A channel's inserts, as in a DAW's mix window: get_max_inserts() slots of plug-ins, played in order before the
    // fader. [{on, plugin_id, plugin_name, plugin_maker, editor_open}], an empty plugin_id where a slot is free.
    Array get_inserts(int id) const;
    // With these settings if any are given; false with the reason in get_error().
    bool set_insert(int id, int slot, const String& plugin_id, const PackedByteArray& state);
    bool clear_insert(int id, int slot);
    void set_insert_on(int id, int slot, bool on);  // off = bypassed
    bool show_insert_editor(int id, int slot, bool show, const String& title);
    // Dragging an insert: moving it swaps it with what is in the slot it goes to; copying it puts a second of the same
    // plug-in there, with the same settings (false with the reason in get_error()).
    bool move_insert(int from_id, int from_slot, int to_id, int to_slot);
    bool copy_insert(int from_id, int from_slot, int to_id, int to_slot);
    int get_max_inserts() const;
    // The plug-in on an insert (`place` "insert", `index` its slot), a Plug-in pedal ("pedal", its place on the
    // board) or a plug-in instrument ("instrument"): its settings, as the plug-in saves them (empty if there is none);
    // putting settings back while it plays; and the presets it comes with, by name.
    PackedByteArray get_plugin_state(int id, const String& place, int index) const;
    bool set_plugin_state(int id, const String& place, int index, const PackedByteArray& state);
    PackedStringArray get_factory_presets(int id, const String& place, int index) const;
    bool load_factory_preset(int id, const String& place, int index, int preset);
    // Preset files as every Audio Unit host shares them (.aupreset): writing a plug-in's settings under a name (false
    // with the reason in get_error()), and reading one back: {plugin_id, name, state}, or {} if it can't be read.
    bool write_plugin_preset(const String& path, const String& name, const PackedByteArray& state);
    Dictionary read_plugin_preset(const String& path);
    void set_listener(const Transform3D& transform);
    void note_on(int id, int note, float velocity);
    void note_off(int id, int note);
    void all_notes_off(int id);
    void set_binaural(bool on);
    void set_reverb(bool on);
    void set_master_volume(float gain);  // the master fader: after the limiter, as on a DAW's master track
    // How many decibels quieter a source gets for each doubling of distance beyond 1.5 m (6 by default: inverse square).
    void set_distance_falloff(float db_per_doubling);
    void set_limiter(bool on);  // off = the plain sum of the mix; either way the output is cut off at full scale
    // The output meter since it was last read: {peak_l, peak_r, rms_l, rms_r, limiter_gain} as linear levels
    // (1 = full scale; limiter_gain 1 = the limiter did nothing) and {clipped}, a count of samples cut off.
    Dictionary read_meter();
    // A source's channel meter, before distance and walls: RMS of its last block, and its highest sample since the last
    // call. After its fader, or with pre_fader before it (after its inserts).
    float get_source_level(int id, bool pre_fader = false) const;
    float get_source_peak(int id, bool pre_fader = false);
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
    // A drum kit's pieces, "drums" (the drum machine), "garage_drums" or "studio_drums": [{name, note}]; and which piece
    // a note plays.
    Array get_drum_pieces(const String& kind) const;
    String get_drum_piece_name(int note, const String& kind) const;

    // ── MIDI ─────────────────────────────────────────────────────────────────────────────────────────────
    // Controllers go straight into the audio core and play every instrument whose input is on.
    bool start_midi();
    void poll_midi();
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
