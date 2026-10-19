#pragma once

// The SoundRoom audio core. Pure C++ with no Godot dependency, so it can be driven by any host:
// the Godot extension, the offline tests, and later other engines.
//
// Threading: one game thread calls the public API, which only pushes small commands onto a lock-free queue.
// The audio thread drains that queue at the start of every block, so it never waits on the game.
// MIDI arrives on the system's MIDI thread and reaches the audio thread through a second queue.

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "amp.h"
#include "instruments.h"
#include "looper.h"
#include "midi_input.h"
#include "mix.h"
#include "pedals.h"
#include "plugin_host.h"
#include "plugin_synth.h"
#include "recorder.h"
#include "wav.h"
#include "room_geometry.h"
#include "sequencer.h"
#include "spatializer.h"
#include "spsc_queue.h"

namespace sr {

struct EngineConfig {
    int sample_rate = 48000;
    int block_size = 128;  // also Steam Audio's frame size
};

enum class DeviceMode {
    Hardware,  // real audio devices
    Null,      // real-time pacing with no sound, for automated runs
};

struct AudioDeviceInfo {
    std::string name;
    bool is_default = false;
    int channels = 0;
};

// Which devices to open and how, in the spirit of a DAW's playback-engine and I/O setup.
struct DeviceConfig {
    DeviceMode mode = DeviceMode::Hardware;
    std::string output_device;  // empty = the system default
    bool input_enabled = false;
    std::string input_device;   // empty = the system default
    int buffer_size = 128;      // frames: the hardware buffer and the engine's block size
    int output_left = 0, output_right = 1;  // which of the device's outputs carry the stereo mix
};

struct EngineStats {
    bool device_running = false;
    bool live_input = false;       // the audio input (microphone, interface) is open
    std::string backend, output_device, input_device;
    int sample_rate = 0, block_size = 0, device_period = 0;
    int output_channels = 0, input_channels = 0;
    double buffer_ms = 0;          // the hardware buffer we fill ahead of playback
    double device_ms = 0;          // what the OS reports for the output device itself (driver, safety offset, hardware)
    double binaural_ms = 0;        // what binaural rendering adds: a quarter of a block (0 while it is switched off)
    double output_latency_ms = 0;  // buffer + device + binaural: from a block being rendered to it being heard
    double input_latency_ms = 0;   // from sound entering the input device to the engine receiving it
    float cpu_load = 0;            // share of each block's time budget spent rendering
    uint64_t blocks = 0;
};

// Where the music is: the tempo everything follows, and the step the clock last reached.
struct TransportState {
    bool running = true;
    double bpm = Sequencer::kDefaultBpm;
    double swing = Sequencer::kDefaultSwing;
    bool click = false;         // the metronome click
    float click_volume = 1.0f;
    int64_t step = -1;          // sixteenths since the sequence started; -1 while it is stopped
};

// What the output meter has seen since it was last read. Levels are linear: 1 is full scale (0 dBFS).
struct MeterReading {
    float peak_l = 0, peak_r = 0;  // the highest sample on each side
    float rms_l = 0, rms_r = 0;    // the average level over the last third of a second or so
    float limiter_gain = 1;        // the lowest gain the limiter applied (1 = it did nothing)
    uint32_t clipped = 0;          // samples that went over full scale and were cut off
    float reverb_peak_l = 0, reverb_peak_r = 0, reverb_rms_l = 0, reverb_rms_r = 0;  // the room reverb's return alone
};

// One of the effect pedals in front of an amp, for the game to show.
struct PedalStatus {
    PedalKind kind = PedalKind::Overdrive;
    bool on = true;
    PedalControls controls{};
    // The Plug-in pedal: what it holds (empty: nothing yet), and whether its window is open.
    PluginDescription plugin;
    bool editor_open = false;
};

// Where a plug-in is: on a Plug-in pedal, an insert, or a plug-in instrument (the instrument itself).
enum class PluginPlace : uint8_t { Pedal, Insert, Instrument };

// A Record room's timeline, as a DAW's edit window has it: each track's clips. Positions in a MIDI clip's notes are in
// steps (sixteenths from the start of bar 1), so they follow the tempo; audio is placed in seconds, as recorded.
struct TimelineNote {
    double step = 0.0;
    float length = 1.0f;  // steps
    int note = 60;
    float velocity = 0.8f;
};
// An audio clip: part of a WAV file (from `offset` seconds into it, `length` long), placed `start` seconds from the
// start of bar 1. Many clips can share one file, as Pro Tools' clips refer to their parent file.
struct ClipSpec {
    std::string path;
    double start = 0.0, offset = 0.0, length = 0.0;
};
// What a recording took: each audio track's file (begun `start_step` into the timeline), and the notes played on
// each MIDI track, as steps on the timeline.
struct RecordingResult {
    double start_step = 0.0, end_step = 0.0, step_seconds = 0.0;  // where it began and ended, and how long a step lasted
    struct Audio {
        int source = -1;
        std::string path;
        double seconds = 0.0;
        int64_t dropped = 0;
    };
    std::vector<Audio> audio;
    struct Note {
        int source = -1;
        TimelineNote note;
    };
    std::vector<Note> notes;
};

// What an amp's loop pedal is doing, for the game to show.
struct LooperStatus {
    bool present = false;  // the amp has a loop pedal on its board
    Looper::State state = Looper::Empty;
    double length = 0, position = 0, capacity = 0;  // seconds
    bool can_undo = false, can_redo = false;
};

class AudioEngine : private StepSink {
public:
    static constexpr int kMaxSources = 32;  // how many instruments the room holds
    // Ids to go round. The spare ones cover sources that have been removed but are still fading out, so that
    // swapping a roomful of instruments for another never has to wait.
    static constexpr int kSourceSlots = 2 * kMaxSources;

    explicit AudioEngine(const EngineConfig& config = {});
    ~AudioEngine() override;

    static std::vector<AudioDeviceInfo> outputDevices();
    static std::vector<AudioDeviceInfo> inputDevices();

    bool init(std::string* error);  // Steam Audio context and HRTF; call once before anything else

    // Closes whatever is open, matches the engine to the chosen output device (its sample rate, and the requested
    // buffer size as the block size) and opens it. On failure nothing is left open.
    bool openDevice(const DeviceConfig& config, std::string* error);
    void stopDevice();
    const DeviceConfig& deviceConfig() const { return device_config_; }
    // Opens or closes the audio input by reopening the device. If the input can't be opened, playback carries on.
    bool setLiveInput(bool enabled, std::string* error);
    void setOutputChannels(int left, int right);  // takes effect immediately

    // Rebuilds the signal processing for a new sample rate or block size. Sources keep their ids and settings but
    // lose any notes that are sounding. Only allowed while no device is open.
    bool configure(int sample_rate, int block_size, std::string* error);

    // ── Game-thread API ──────────────────────────────────────────────────────────────────────────────────
    // Returns an id, or -1 if the room already holds kMaxSources. A new source has an empty pattern.
    int addSource(InstrumentKind kind, Vec3 position, float gain, float reverb_send);
    // Takes a source out of the room. It fades out over a few blocks, and its id is reused once the audio thread
    // has let go of it; it stops counting towards kMaxSources at once. False if there is no such source.
    bool removeSource(int id);
    int sourceCount() const;  // how many are in the room
    void setSourcePosition(int id, Vec3 position);
    bool sourceBlocked(int id) const;  // a wall stands between it and the listener
    void setSourceGain(int id, float gain);  // its level, as heard within the reference distance (1 = as added)
    // The instrument's own volume in the room, after its inserts and before its fader: a Speaker's level knob, as on a
    // powered PA speaker. 1 = as it comes in.
    void setSourceVolume(int id, float gain);

    // ── The room ─────────────────────────────────────────────────────────────────────────────────────────
    // The room's inside dimensions in metres and the walls standing in it. The engine works out how each source's
    // sound reaches the listener round the walls, again whenever a source, the listener or the room changes.
    // The size also sets how long and how loudly the room rings: a bigger room rings longer but more quietly.
    // The walls take effect at once. The reverb is rebuilt on the calling thread and faded in, one change at a
    // time, so after a burst of changes it catches up over the following calls to setListener or roomSettled.
    void setRoom(float width, float height, float depth, const std::vector<Wall>& walls);
    bool roomSettled();  // false while the reverb has yet to catch up with the room's size
    float roomDecaySeconds() const { return wanted_rt60_; }  // the reverb time (RT60) that goes with the size
    // Overrides what the engine worked out for one source (used by the offline checks). `via` is the point the
    // sound arrives from (the source itself, or the wall edge it bends around), `extra_length` is the distance from
    // `via` on to the source, and `path_differences` lists how much longer each route around the wall is than the
    // straight line (one negative entry if the line of sight is clear: by how little it clears the nearest edge).
    // It holds until the source or the listener next moves.
    void setSourceDirectPath(int id, Vec3 via, float extra_length, const float* path_differences, int count, bool blocked);
    void setSourceMuted(int id, bool muted);
    // For live-input sources: which hardware input to play (0-based), or LiveInput::kAllInputs.
    void setSourceInputChannel(int id, int channel);
    // Whether a source takes input, as a track's input is switched on in a DAW. An instrument with its input on plays
    // what MIDI controllers send (all such instruments at once); a live-input source plays its hardware input.
    // Every source starts with its input off.
    void setSourceInput(int id, bool on);

    // ── Amps ─────────────────────────────────────────────────────────────────────────────────────────────
    static constexpr double kLoopSeconds = 90.0;  // the longest loop a pedal holds
    void setAmpControl(int id, AmpControl control, float value);  // a knob, 0 to 10
    // Which head and cabinet an amp has, and whether each is in use (bypassed, a head passes the signal straight to the
    // cabinet, and a cabinet becomes a flat full-range speaker). An amp starts with its kind's own.
    void setAmpHead(int id, AmpHead head, bool on);
    void setAmpCabinet(int id, AmpCabinet cabinet, bool on);
    // The loop pedal on an amp's board (a PedalKind::Looper; see addPedal), whose controls are its level (5 = as
    // recorded), Sync (recordings start and end on bar lines while the patterns run) and whether finishing the first
    // recording goes straight into overdubbing. The first Press gives it its memory (two buffers of kLoopSeconds),
    // allocated here on the calling thread. False if the amp has no loop pedal.
    bool looperAction(int id, Looper::Action action);
    LooperStatus looperStatus(int id) const;

    // The effect pedals in front of an amp (pedals.h), up to kMaxPedals, numbered in the order the signal passes
    // through them. A new pedal is switched on, with its controls where they start. Each call takes effect at the next
    // block; pedals taken off the board are freed once the audio thread has let go of them.
    // Where it went, or -1: not an amp, the board is full, or a second loop pedal.
    int addPedal(int id, PedalKind kind, int at = -1);
    bool removePedal(int id, int index);
    bool movePedal(int id, int from, int to);
    // A second of a pedal, as Option-dragging one does: the same kind, switched the same way, with the same controls
    // (a Plug-in pedal holds the same plug-in, with the same settings), put on this amp's board or another's at `at`
    // (-1: the end). A loop pedal comes without its loop. Where it went, or -1 with the reason.
    int copyPedal(int from_id, int index, int to_id, int at, std::string* error);
    void setPedalOn(int id, int index, bool on);
    void setPedalControl(int id, int index, int control, float value);
    std::vector<PedalStatus> pedals(int id) const;
    TunerReading tuner(int id) const;  // what the amp's first tuner hears, while it is on
    // Plug-ins (plugin_host.h): every effect plug-in installed, and loading one into a Plug-in pedal, replacing what
    // it held. Both on the game thread, which on macOS must be the main thread. False, with the reason, if it fails.
    static std::vector<PluginDescription> effectPlugins() { return PluginInstance::available(); }
    // With `state`, the plug-in is given those settings before it plays.
    bool loadPedalPlugin(int id, int index, const std::string& plugin_id, std::string* error, const std::vector<uint8_t>* state = nullptr);
    // The plug-in's own window; `title` names it. False if there is no plug-in there.
    bool showPluginEditor(int id, int index, bool show, const std::string& title = "");

    // ── Inserts ──────────────────────────────────────────────────────────────────────────────────────────
    // Plug-ins on any source's channel, as in the inserts of a DAW's mix window: kMaxInserts slots, played in order
    // on the instrument's sound before its fader (for an amp, after its pedals and the amp itself). Each slot holds a
    // plug-in or nothing, and a plug-in can be bypassed. Game thread, which on macOS must be the main thread.
    static constexpr int kMaxInserts = 5;
    // Replaces what was there; with `state`, the plug-in is given those settings before it plays.
    bool setInsert(int id, int slot, const std::string& plugin_id, std::string* error, const std::vector<uint8_t>* state = nullptr);
    bool clearInsert(int id, int slot);
    void setInsertOn(int id, int slot, bool on);  // off = bypassed
    std::vector<PedalStatus> inserts(int id) const;  // one for each slot; an empty `plugin` where there is none
    bool showInsertEditor(int id, int slot, bool show, const std::string& title = "");
    // Dragging inserts about, as in Pro Tools: moving one to another slot, on this channel or another, swaps it with
    // whatever was there; copying one (Option-drag) puts a second of the same plug-in there, with the same settings,
    // in place of what was there.
    bool moveInsert(int from_id, int from_slot, int to_id, int to_slot);
    bool copyInsert(int from_id, int from_slot, int to_id, int to_slot, std::string* error);
    // The plug-in on an insert (`index` its slot), a Plug-in pedal (`index` its place on the board) or a plug-in
    // instrument: its settings as it saves them (empty if there is no plug-in there), putting settings back while it
    // plays, as a DAW loads a preset, and the presets it comes with. Game thread.
    std::vector<uint8_t> pluginState(int id, PluginPlace place, int index) const;
    bool setPluginState(int id, PluginPlace place, int index, const std::vector<uint8_t>& state);
    std::vector<std::string> factoryPresets(int id, PluginPlace place, int index) const;
    bool loadFactoryPreset(int id, PluginPlace place, int index, int preset);

    // ── Plug-in instruments ──────────────────────────────────────────────────────────────────────────────
    // A source of kind PluginSynth plays one of the instrument plug-ins installed. Loading one replaces what it held
    // (with these settings, if given); false with the reason. Game thread, which on macOS must be the main thread.
    static std::vector<PluginDescription> instrumentPlugins() { return PluginInstance::availableInstruments(); }
    bool setInstrumentPlugin(int id, const std::string& plugin_id, std::string* error, const std::vector<uint8_t>* state = nullptr);
    PluginDescription instrumentPlugin(int id) const;  // what it holds (an empty id if nothing)
    bool instrumentEditorOpen(int id) const;
    bool showInstrumentEditor(int id, bool show, const std::string& title = "");
    void placeInstrumentEditor(int id, double above_bottom);  // see PluginInstance::placeEditor
    void setListener(Vec3 position, Vec3 ahead, Vec3 up);
    void noteOn(int id, int note, float velocity);
    void noteOff(int id, int note);
    void allNotesOff(int id);
    // Binaural (HRTF) rendering, or plain stereo panning to compare it with. Binaural comes out a quarter of a block
    // later (EngineStats::binaural_ms), and the reverb and the click with it. Switching crossfades between the two.
    void setBinaural(bool on);
    void setReverb(bool on);              // as setReverbLevel(1) or (0)
    void setReverbLevel(float gain);      // the room reverb's return: 1 is as the room has it, 0 none; up to 4
    // The master fader, after the limiter as on a DAW's master track: the limiter's inserts come before the fader, so
    // how hard it works doesn't depend on where the fader sits. 1 = normal; above 1 the output can clip again.
    void setMasterVolume(float gain);
    // How much quieter a source gets for each doubling of its distance beyond the reference distance (1.5 m), in
    // decibels. The default, 6, is the inverse square law; less keeps levels more even as the listener moves about.
    // Within the reference distance a source is at its own level and gets no louder, however close.
    void setDistanceFalloff(float db_per_doubling);
    // The limiter keeps the mix from ever reaching full scale on its way into the master fader. With it off the
    // output is what the mix adds up to. Either way, anything leaving the master fader over full scale is cut off
    // (and counted by the meter).
    void setLimiter(bool on);
    MeterReading readMeter();  // the output meter; reading it starts a new measurement

    // ── The sequencer ────────────────────────────────────────────────────────────────────────────────────
    // Every source has a pattern (empty to begin with) that the clock plays round and round.
    void loadDefaultPattern(int id);  // the built-in groove's part for this kind of instrument
    void setPattern(int id, const std::vector<PatternNote>& notes);
    // Adds a note, or replaces the one already at that step and pitch. False if the pattern is full.
    bool setPatternNote(int id, const PatternNote& note);
    void removePatternNote(int id, int step, int note);
    void setPatternSteps(int id, int steps);  // how long the pattern is before it repeats: 16, 32 or 64
    std::vector<PatternNote> pattern(int id) const;
    int patternSteps(int id) const;
    void setSourceLoop(int id, bool on);  // whether the sequencer plays this source's pattern
    void setSequencerRunning(bool on);    // stopping silences the patterns; starting begins again from the top

    // ── The timeline (a Record room) ─────────────────────────────────────────────────────────────────────
    // Playing from a step (sixteenths from the start of bar 1: the patterns follow, each from its own start every time
    // round), stopping (setSequencerRunning(false)), and loop playback over a range of steps.
    void playFrom(double step);
    void setLoopRange(bool on, double start_step, double end_step);  // anywhere, not only on steps
    double timelinePosition() const { return position_.load(std::memory_order_relaxed); }  // in steps, as last rendered
    // A track's clips: notes to play (an instrument) and audio to play into it (a Speaker or an amp, through its pedals,
    // amp and inserts as its input would be). Files are read (once each) on this thread. False, with the reason, if
    // one couldn't be read; the rest are used.
    bool setTrack(int id, const std::vector<TimelineNote>& notes, const std::vector<ClipSpec>& clips, std::string* error);
    // An audio file's loudest sample in each `1 / per_second` of a second, for drawing its clips (read once and kept).
    std::vector<float> audioPeaks(const std::string& path, double per_second);
    double audioSeconds(const std::string& path);  // 0 if it can't be read

    // ── Recording ────────────────────────────────────────────────────────────────────────────────────────
    // Arming a track for recording. An armed Speaker or amp records its hardware input as it comes in (before its
    // pedals, amp and inserts); an armed instrument records the notes played on it.
    void setRecordArm(int id, bool armed);
    // From the next block: the armed tracks record (audio to `files`, one per armed audio track: [source, path]),
    // the timeline playing on from where it is, or from `from_step` if it is stopped. Loop playback waits meanwhile.
    bool startRecording(const std::vector<std::pair<int, std::string>>& files, double from_step, std::string* error);
    void stopRecording();  // from the next block; takeRecording then has it
    bool recording() const { return recording_wanted_; }
    // Once the audio thread has stopped recording: what it took, the files closed. False until then.
    bool takeRecording(RecordingResult* out);
    void setTempo(double bpm);
    void setSwing(double amount);         // 0 = straight; off-beat sixteenths land this fraction of a step late
    void setClick(bool on);               // a metronome click on every beat, heard directly rather than in the room
    void setClickVolume(float gain);
    TransportState transport() const;

    // MIDI controllers play every instrument whose input is on (see setSourceInput).
    bool startMidi(std::string* error);
    void pollMidi();  // picks up controllers plugged in since the last call
    std::vector<MidiDeviceInfo> midiDevices() const { return midi_.devices(); }
    void setMidiDeviceEnabled(const std::string& name, bool enabled) { midi_.setEnabled(name, enabled); }
    uint32_t midiEventCount() const { return midi_events_.load(std::memory_order_relaxed); }

    // A source's channel meter: the RMS of its last block, and its highest sample since the last call (reading it
    // starts again), before distance and walls. After its fader and mute, or with `pre_fader` before them (and after
    // its inserts), as a DAW's pre-fader metering shows.
    float sourceLevel(int id, bool pre_fader = false) const;
    float sourcePeak(int id, bool pre_fader = false);
    EngineStats stats() const;
    int sampleRate() const { return sr_; }
    int blockSize() const { return block_; }

    // Renders interleaved stereo. `input` holds the audio captured over the same frames, interleaved with
    // `input_channels` channels (or null). Called through renderDevice, or directly for offline rendering.
    void render(const float* input, int input_channels, float* stereo, int frames);
    void render(const float* mono_input, float* stereo, int frames) { render(mono_input, mono_input ? 1 : 0, stereo, frames); }
    void render(float* stereo, int frames) { render(nullptr, 0, stereo, frames); }
    // What the device callback calls: any channel layout in and out, with the mix placed on the chosen outputs.
    void renderDevice(const float* input, int input_channels, float* output, int output_channels, int frames);

private:
    struct Source;
    struct Device;
    struct Command {
        enum Type : uint8_t {
            AddSource, RemoveSource, SourcePosition, SourceDirectPath, SourceMuted, SourceInputChannel, Listener,
            NoteOn, NoteOff, AllNotesOff, Binaural, Reverb, MasterVolume, SourceInput,
            PatternNoteSet, PatternNoteRemove, PatternClear, PatternSteps, SourceLoop, SourceVolume,
            SequencerRunning, Tempo, Swing, Click, ClickVolume, Reverb2, SourceGain, Falloff, LimiterOn,
            AmpKnob, AmpHeadSet, AmpCabinetSet, LooperMemory, LooperAct, PedalBoardSet, PedalOn, PedalControl, SynthPlugin,
            TimelinePlay, TimelineLoop, TrackSet, RecordArm, RecordStart, RecordStop,
        } type = AddSource;
        int id = 0;
        float v[9] = {};
        Source* source = nullptr;
        float* memory[2] = {nullptr, nullptr};  // LooperMemory
        int64_t count = 0;
        // PedalBoardSet: the new order (`count` of them; v[0] is 0 for the pedals, 1 for the inserts). PedalOn,
        // PedalControl, LooperMemory and LooperAct: the pedal, [0]. SynthPlugin: the plug-in instrument's, [0]
        // (a PluginPedal holding it), or none.
        Pedal* pedals[kMaxPedals] = {};
        uint32_t epoch = 0;
        void* data = nullptr;  // TrackSet: the track's timeline; RecordStart: the recorder
    };

    void push(const Command& c);
    void drainCommands();
    void drainMidi();
    void renderBlock();
    void allocateBuffers();
    std::unique_ptr<Instrument> makeInstrument(InstrumentKind kind) const;
    void connect(Source& source);  // an amp's pedals and knobs, after its instrument is (re)built
    bool sendBoard(Source& source, bool inserts = false);  // hands the audio thread the pedals (or inserts) anew
    LooperPedal* looperOf(const Source& source) const;     // the loop pedal on its board, if any
    PluginInstance* pluginAt(int id, PluginPlace place, int index) const;
    // A Plug-in pedal holding this plug-in, ready to play (and given these settings, if any); null, with the reason.
    std::unique_ptr<PluginPedal> makePluginPedal(const std::string& plugin_id, const std::vector<uint8_t>* state, std::string* error);
    bool placeInsert(Source& source, int slot, std::unique_ptr<PluginPedal> pedal, bool on, std::string* error);
    void reapPedals();              // frees pedals (and tracks' timelines) the audio thread has let go of
    void renderTimeline();          // this block's place on the timeline, and each track's recorded audio
    std::shared_ptr<const AudioData> audioFile(const std::string& path, std::string* error);
    Source* owned(int id) const;  // the source with this id, unless it is on its way out
    void reap();                  // frees removed sources the audio thread has finished with
    void updatePath(Source& source);  // works out how its sound reaches the listener and tells the audio thread
    void updatePaths();
    int delayFor(double at) const;

    // StepSink: plays every source's pattern notes for this step, and the click.
    void step(int64_t index, double at, double step_samples) override;

    int sr_, block_;
    SteamAudio steam_;
    bool initialized_ = false;

    // Game-thread state
    std::vector<std::unique_ptr<Source>> owned_;  // indexed by id; a removed source leaves an empty slot
    std::vector<std::pair<std::string, std::shared_ptr<const AudioData>>> audio_files_;  // read once each
    std::unique_ptr<Recorder> recorder_;
    bool recording_wanted_ = false;
    uint32_t record_epoch_ = 0;
    SpscQueue<Command> commands_{8192};
    std::unique_ptr<Device> device_;
    EngineStats device_stats_;
    DeviceConfig device_config_;
    MidiInput midi_;
    TransportState transport_;  // what the game asked for; the audio thread follows
    bool binaural_wanted_ = true;  // likewise; stats() reports the latency that goes with it
    RoomGeometry geometry_;
    Vec3 ear_{0, 1.65f, 0};     // where the listener was last put
    // The reverb the room's size calls for, and the one that has been handed to the audio thread so far.
    float wanted_rt60_, wanted_size_ = 1.0f, wanted_level_;
    float room_rt60_, room_size_ = 1.0f, room_level_;
    int reverb_spare_ = 1;      // which of the two reverbs the audio thread is not using

    // MIDI thread → audio thread
    SpscQueue<MidiEvent> midi_queue_{1024};
    std::atomic<uint32_t> midi_events_{0};

    // Audio-thread state
    std::array<Source*, kSourceSlots> sources_{};
    Vec3 listener_pos_{0, 1.65f, 0}, listener_ahead_{0, 0, -1}, listener_up_{0, 1, 0};
    Vec3 target_pos_{0, 1.65f, 0}, target_ahead_{0, 0, -1}, target_up_{0, 1, 0};
    bool binaural_ = true;
    float binaural_mix_ = 1.0f;  // the share of the sound rendered binaurally just now: glides to 0 or 1 when it is switched
    float reverb_target_ = 1.0f, reverb_gain_ = 1.0f;
    float master_target_ = 1.0f, master_gain_ = 1.0f;
    float falloff_target_, falloff_;
    bool limiter_on_ = true;
    float meter_ms_l_ = 0.0f, meter_ms_r_ = 0.0f;  // running mean squares for the meter
    Sequencer sequencer_;
    Rng rng_{0x6C078965u};  // for notes that only play some of the time
    std::array<voice::ToneHit, 4> clicks_;
    bool click_on_ = false;
    float click_volume_ = 1.0f;
    // Two reverbs, so the room can change without a click: the new one is built in the spare, then faded in.
    std::array<FdnReverb, 2> reverbs_;
    int reverb_active_ = 0, reverb_next_ = 0, reverb_fade_left_ = 0, reverb_fade_len_ = 1;
    float reverb_level_, reverb_next_level_ = 0.0f;
    Limiter limiter_;
    // The reverb's feed and the click bypass the binaural rendering, which comes out a little late: these hold them
    // back by as much while binaural is on, so the mix lines up the same way at every block size.
    FadedDelay send_delay_, click_delay_;
    std::vector<float> mix_l_, mix_r_, send_, rev_l_, rev_r_, rev2_l_, rev2_r_, click_;
    InputBus input_bus_;               // this block's captured audio, per hardware input
    std::vector<float> input_fifo_;    // captured frames (interleaved) waiting to be rendered
    int fifo_channels_ = 0;
    size_t input_read_ = 0, input_count_ = 0;  // in frames
    int block_pos_;
    int64_t clock_ = 0;  // samples rendered since start: the engine's shared musical clock
    int64_t bar_timing_[2] = {-1, 0};  // for the loop pedals: samples from this block's start to the next bar line, a bar

    // Shared between threads
    std::array<std::atomic<float>, kSourceSlots> levels_{}, peaks_{}, pre_levels_{}, pre_peaks_{};
    std::atomic<float> cpu_load_{0.0f};
    std::atomic<uint64_t> blocks_{0};
    std::atomic<int> out_left_{0}, out_right_{1};
    std::atomic<int64_t> step_{-1};
    std::atomic<float> meter_peak_l_{0.0f}, meter_peak_r_{0.0f}, meter_rms_l_{0.0f}, meter_rms_r_{0.0f}, meter_gain_{1.0f};
    std::atomic<float> reverb_peak_l_{0.0f}, reverb_peak_r_{0.0f}, reverb_rms_l_{0.0f}, reverb_rms_r_{0.0f};
    float reverb_ms_l_ = 0.0f, reverb_ms_r_ = 0.0f;
    std::atomic<uint32_t> meter_clipped_{0};
    std::atomic<bool> reverb_changing_{false};  // set by the game thread with a new reverb, cleared when it has faded in
    // The timeline and recording
    std::atomic<double> position_{0.0};
    std::vector<double> block_seconds_;  // each sample of this block's place on the timeline, in seconds (-1: stopped)
    Recorder* recorder_rt_ = nullptr;  // the audio thread's view of recorder_, while recording
    bool recording_ = false;
    std::atomic<uint32_t> record_ack_{0};
    std::atomic<double> record_start_{0.0}, record_end_{0.0}, record_step_seconds_{0.0};
    struct Captured {
        int source = -1, note = 0;
        float velocity = 0.0f;
        bool on = false;
        double step = 0.0;
    };
    SpscQueue<Captured> captured_{8192};  // notes played on armed instruments while recording
    std::vector<float> take_;  // what a track takes in, this block
};

}  // namespace sr
