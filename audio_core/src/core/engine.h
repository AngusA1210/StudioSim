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

#include "instruments.h"
#include "midi_input.h"
#include "mix.h"
#include "sequencer.h"
#include "spatializer.h"
#include "spsc_queue.h"

namespace sr {

struct EngineConfig {
    int sample_rate = 48000;
    int block_size = 128;  // also Steam Audio's frame size
};

enum class DeviceMode {
    Hardware,  // the system's default devices
    Null,      // real-time pacing with no sound, for automated runs
};

struct EngineStats {
    bool device_running = false;
    bool live_input = false;       // the audio input (microphone, interface) is open
    std::string backend, input_device;
    int sample_rate = 0, block_size = 0, device_period = 0;
    double buffer_ms = 0;          // the device period we fill ahead of playback
    double device_ms = 0;          // what the OS reports for the output device itself (driver, safety offset, hardware)
    double output_latency_ms = 0;  // buffer + device: from a block being rendered to it being heard
    double input_latency_ms = 0;   // from sound entering the input device to the engine receiving it
    float cpu_load = 0;            // share of each block's time budget spent rendering
    uint64_t blocks = 0;
};

class AudioEngine : private SequencerSink {
public:
    static constexpr int kMaxSources = 32;

    explicit AudioEngine(const EngineConfig& config = {});
    ~AudioEngine() override;

    // The sample rate the default output device runs at, so the engine can match it instead of resampling
    // (resampling would add latency). Returns 48000 if the device doesn't say.
    static int defaultOutputSampleRate();

    bool init(std::string* error);  // Steam Audio context and HRTF; call once before anything else
    bool startDevice(DeviceMode mode, bool with_input, std::string* error);
    void stopDevice();
    // Opens or closes the audio input by reopening the device. If the input can't be opened, playback carries on.
    bool setLiveInput(bool enabled, std::string* error);

    // ── Game-thread API ──────────────────────────────────────────────────────────────────────────────────
    int addSource(InstrumentKind kind, Vec3 position, float gain, float reverb_send);  // returns an id, or -1
    // Places a source with a clear line of sight to the listener.
    void setSourcePosition(int id, Vec3 position);
    // How the source's sound reaches the listener when walls are involved. `via` is the point the sound arrives
    // from (the source itself, or the wall edge it bends around), `extra_length` is the distance from `via` on to
    // the source, and `path_differences` lists how much longer each route around the wall is than the straight
    // line (one negative entry if the line of sight is clear: by how little it clears the nearest edge).
    void setSourceDirectPath(int id, Vec3 via, float extra_length, const float* path_differences, int count, bool blocked);
    void setSourceMuted(int id, bool muted);
    void setListener(Vec3 position, Vec3 ahead, Vec3 up);
    void noteOn(int id, int note, float velocity);
    void noteOff(int id, int note);
    void allNotesOff(int id);
    void setBinaural(bool on);
    void setReverb(bool on);
    void setSequencerRunning(bool on);

    // MIDI controllers play `setMidiTarget`'s source; by default the first Keys in the room.
    bool startMidi(std::string* error);
    void pollMidi();  // picks up controllers plugged in since the last call
    void setMidiTarget(int id);
    std::vector<std::string> midiDevices() const;
    uint32_t midiEventCount() const { return midi_events_.load(std::memory_order_relaxed); }

    float sourceLevel(int id) const;  // RMS of the source's last block, before distance and walls
    EngineStats stats() const;
    int sampleRate() const { return sr_; }
    int blockSize() const { return block_; }

    // Renders interleaved stereo float. `input` is mono audio captured over the same frames, or null.
    // Called by the device, or directly for offline rendering.
    void render(const float* input, float* interleaved, int frames);
    void render(float* interleaved, int frames) { render(nullptr, interleaved, frames); }

private:
    struct Source;
    struct Device;
    struct Command {
        enum Type : uint8_t {
            AddSource, SourcePosition, SourceDirectPath, SourceMuted, Listener,
            NoteOn, NoteOff, AllNotesOff, Binaural, Reverb, SequencerRunning, MidiTarget,
        } type = AddSource;
        int id = 0;
        float v[9] = {};
        Source* source = nullptr;
    };

    void push(const Command& c);
    void drainCommands();
    void drainMidi();
    void renderBlock();
    Source* role(InstrumentKind kind) const { return roles_[size_t(kind)]; }
    int delayFor(double at) const;

    // SequencerSink: the groove plays on whichever source has the matching instrument
    void kick(double at, float velocity) override;
    void snare(double at, float velocity) override;
    void hat(double at, float velocity, bool open) override;
    void bass(double at, int note, float dur_sec, float velocity) override;
    void pad(double at, const int* notes, int count, float dur_sec, float velocity) override;
    void bell(double at, int note, float velocity) override;

    const int sr_, block_;
    SteamAudio steam_;
    bool initialized_ = false;

    // Game-thread state
    std::vector<std::unique_ptr<Source>> owned_;
    SpscQueue<Command> commands_{8192};
    std::unique_ptr<Device> device_;
    EngineStats device_stats_;
    DeviceMode device_mode_ = DeviceMode::Hardware;
    MidiInput midi_;

    // MIDI thread → audio thread
    SpscQueue<MidiEvent> midi_queue_{1024};
    std::atomic<uint32_t> midi_events_{0};

    // Audio-thread state
    std::array<Source*, kMaxSources> sources_{};
    std::array<Source*, kInstrumentKinds> roles_{};
    int midi_target_ = -1;
    Vec3 listener_pos_{0, 1.65f, 0}, listener_ahead_{0, 0, -1}, listener_up_{0, 1, 0};
    Vec3 target_pos_{0, 1.65f, 0}, target_ahead_{0, 0, -1}, target_up_{0, 1, 0};
    bool binaural_ = true;
    float reverb_target_ = 1.0f, reverb_gain_ = 1.0f;
    Sequencer sequencer_;
    FdnReverb reverb_;
    Limiter limiter_;
    std::vector<float> mix_l_, mix_r_, send_, rev_l_, rev_r_;
    std::vector<float> input_fifo_, input_block_;  // captured audio waiting to be rendered, and the current block's share
    size_t input_read_ = 0, input_count_ = 0;
    int block_pos_;
    int64_t clock_ = 0;  // samples rendered since start: the engine's shared musical clock

    // Shared between threads
    std::array<std::atomic<float>, kMaxSources> levels_{};
    std::atomic<float> cpu_load_{0.0f};
    std::atomic<uint64_t> blocks_{0};
};

}  // namespace sr
