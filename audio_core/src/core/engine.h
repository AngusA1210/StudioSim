#pragma once

// The SoundRoom audio core. Pure C++ with no Godot dependency, so it can be driven by any host:
// the Godot extension, the offline tests, and later other engines.
//
// Threading: one game thread calls the public API, which only pushes small commands onto a lock-free queue.
// The audio thread drains that queue at the start of every block, so it never waits on the game.

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "instruments.h"
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
    Hardware,  // the system's default output device
    Null,      // real-time pacing with no sound, for automated runs
};

struct EngineStats {
    bool device_running = false;
    std::string backend;
    int sample_rate = 0, block_size = 0, device_period = 0;
    double buffer_ms = 0;          // the device period we fill ahead of playback
    double device_ms = 0;          // what the OS reports for the output device itself (driver, safety offset, hardware)
    double output_latency_ms = 0;  // buffer + device: from a block being rendered to it being heard
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
    bool startDevice(DeviceMode mode, std::string* error);
    void stopDevice();

    // ── Game-thread API ──────────────────────────────────────────────────────────────────────────────────
    int addSource(InstrumentKind kind, Vec3 position, float gain, float reverb_send);  // returns an id, or -1
    void setSourcePosition(int id, Vec3 position);
    void setSourceMuted(int id, bool muted);
    void setSourceVisibility(int id, float visible);  // 1 = clear line of sight, 0 = fully blocked
    void setListener(Vec3 position, Vec3 ahead, Vec3 up);
    void noteOn(int id, int note, float velocity);
    void noteOff(int id, int note);
    void allNotesOff(int id);
    void setBinaural(bool on);
    void setReverb(bool on);
    void setSequencerRunning(bool on);

    float sourceLevel(int id) const;  // RMS of the source's last block, before distance and walls
    EngineStats stats() const;
    int sampleRate() const { return sr_; }
    int blockSize() const { return block_; }

    // Renders interleaved stereo float. Called by the device, or directly for offline rendering.
    void render(float* interleaved, int frames);

private:
    struct Source;
    struct Device;
    struct Command {
        enum Type : uint8_t {
            AddSource, SourcePosition, SourceMuted, SourceVisibility, Listener,
            NoteOn, NoteOff, AllNotesOff, Binaural, Reverb, SequencerRunning,
        } type = AddSource;
        int id = 0;
        float v[9] = {};
        Source* source = nullptr;
    };

    void push(const Command& c);
    void drainCommands();
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

    // Audio-thread state
    std::array<Source*, kMaxSources> sources_{};
    std::array<Source*, 5> roles_{};
    Vec3 listener_pos_{0, 1.65f, 0}, listener_ahead_{0, 0, -1}, listener_up_{0, 1, 0};
    Vec3 target_pos_{0, 1.65f, 0}, target_ahead_{0, 0, -1}, target_up_{0, 1, 0};
    bool binaural_ = true;
    float reverb_target_ = 1.0f, reverb_gain_ = 1.0f;
    Sequencer sequencer_;
    FdnReverb reverb_;
    Limiter limiter_;
    std::vector<float> mix_l_, mix_r_, send_, rev_l_, rev_r_;
    int block_pos_;
    int64_t clock_ = 0;  // samples rendered since start: the engine's shared musical clock

    // Shared between threads
    std::array<std::atomic<float>, kMaxSources> levels_{};
    std::atomic<float> cpu_load_{0.0f};
    std::atomic<uint64_t> blocks_{0};
};

}  // namespace sr
