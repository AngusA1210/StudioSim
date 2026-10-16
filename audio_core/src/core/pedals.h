#pragma once

// Effect pedals, as stand on the floor between a guitar and its amp. An amp has a board of up to kMaxPedals, which
// the signal passes through in order, then the loop pedal, then the amp. Each pedal has a footswitch (on, or bypassed:
// the signal passes untouched) and up to kPedalControls controls: knobs from 0 to 10 as printed on the pedal, and
// switches (0 or 1). The Plug-in pedal holds one of the effect plug-ins installed on the computer (plugin_host.h).
//
//   Tuner            mutes the guitar while it is on (unless Mute is off) and says which note it hears
//   Noise Gate       Threshold, Release: silences the hiss and hum between notes
//   Compressor       Sustain, Attack, Level, Blend: evens out the playing
//   Overdrive        Drive, Tone, Level: a mid-humped soft clip that keeps the lows clean
//   Fuzz             Sustain, Tone, Volume: two hard-clipping stages and a scooped tone control
//   Envelope Filter  Sensitivity, Range, Resonance, Band-pass: a filter that opens the harder you play (auto-wah)
//   Chorus           Rate, Depth, Mix: a slowly wavering copy alongside the dry signal (Mix 10 is vibrato)
//   Phaser           Rate, Depth, Resonance: four all-pass stages swept up and down
//   Tremolo          Rate, Depth, Shape: the volume pulsing, from a smooth sine to a hard chop
//   Delay            Time, Repeats, Mix, Tone, Sync: echoes, darker with each repeat; Sync sets the time in beats
//   Reverb           Decay, Tone, Mix: a room or hall
//
// Delay and Reverb let their echoes and tail ring on after they are switched off, as many real ones do.
//
// A pedal's memory is allocated by prepare(), on the game thread, before it is handed to the audio thread (or while
// the audio device is closed). After that only the audio thread touches it, to process it and turn its controls.

#include <array>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include "dsp.h"

namespace sr {

class PluginInstance;

enum class PedalKind : int {
    Tuner, Gate, Compressor, Overdrive, Fuzz, EnvelopeFilter, Chorus, Phaser, Tremolo, Delay, Reverb, Plugin, kCount
};
constexpr int kPedalKinds = int(PedalKind::kCount);
constexpr int kPedalControls = 5;
constexpr int kMaxPedals = 8;

using PedalControls = std::array<float, kPedalControls>;
PedalControls defaultPedalControls(PedalKind kind);  // where each control starts
int pedalControlCount(PedalKind kind);

// What a tuner hears.
struct TunerReading {
    bool listening = false;  // a tuner is on
    bool pitched = false;    // ...and hears a clear note
    double frequency = 0;    // Hz
    int note = 0;            // the nearest MIDI note (69 is A above middle C, at 440 Hz)
    double cents = 0;        // how far the note is from it, -50 to +50
};

// The pitch of a run of samples at `rate` Hz (the YIN method), between about 25 Hz (a five-string bass's low B is
// 31 Hz) and 1.4 kHz. Not pitched if it is too quiet or too noisy to tell.
TunerReading detectPitch(const float* x, int n, float rate);

class Pedal {
public:
    // A stock pedal of any kind but Plugin, prepared at this sample rate, with its default controls, switched on.
    static std::unique_ptr<Pedal> make(PedalKind kind, float sample_rate);
    virtual ~Pedal() = default;
    PedalKind kind() const { return kind_; }

    // Game thread, while the audio thread can't be processing it.
    virtual void prepare(float sample_rate);

    // Audio thread (or the game thread, before it is handed over).
    void setOn(bool on) {
        on_ = on;
        if (!started_) share_ = on ? 1.0f : 0.0f;  // switched before it has played anything: no fade to make
    }
    void setControl(int index, float value);
    // In place. `beat_samples` is how long a beat lasts at the room's tempo, for a pedal that keeps time with it.
    void process(float* io, int n, double beat_samples);

protected:
    explicit Pedal(PedalKind kind);
    float control(int index) const { return controls_[size_t(index)]; }
    virtual void update() {}  // the controls changed: work out what they mean (audio thread, before the next block)
    virtual void clear() {}   // coming back on after being bypassed: forget what it held
    virtual void run(float* io, int n, double beat_samples) = 0;  // the effect itself, while on
    // A pedal whose sound rings on after it is switched off takes care of its own bypass: what it hears is faded from
    // `feed_from` to `feed_to` over the block (1 = on, 0 = off), and what it makes is always added to the signal.
    virtual bool trails() const { return false; }
    virtual void runTrails(float*, int, float, float, double) {}

    float sr_ = 48000.0f;

private:
    PedalKind kind_;
    PedalControls controls_{};
    bool on_ = true, changed_ = true, started_ = false;
    float share_ = 1.0f;  // how much of the effect is heard: glides between 0 and 1 when it is switched
};

// The pedals in front of one amp, in the order the signal passes through them: the audio thread's copy of the order.
struct PedalBoard {
    std::array<Pedal*, kMaxPedals> pedals{};
    int count = 0;
};

// The tuner keeps what it hears where the game thread can look at it.
class TunerPedal final : public Pedal {
public:
    TunerPedal();
    void prepare(float sample_rate) override;
    TunerReading read() const;  // game thread: the note in the last tenth of a second or so

protected:
    void clear() override;
    void run(float* io, int n, double beat_samples) override;

private:
    static constexpr int kRing = 4096;
    int factor_ = 4, phase_ = 0;  // it listens at a quarter of the sample rate or so, which is plenty for pitch
    float rate_ = 12000.0f;
    Biquad smooth_[2];  // the anti-aliasing filter before that
    std::unique_ptr<std::atomic<float>[]> ring_;
    std::atomic<uint32_t> written_{0};
};

// The Plug-in pedal: an effect plug-in, or nothing yet (the signal passes through).
class PluginPedal final : public Pedal {
public:
    explicit PluginPedal(std::unique_ptr<PluginInstance> plugin = nullptr);
    ~PluginPedal() override;
    PluginInstance* plugin() const { return plugin_.get(); }
    void prepare(float sample_rate) override;  // readies the plug-in too
    bool ready() const { return ready_; }
    const std::string& error() const { return error_; }  // why it isn't ready

protected:
    void run(float* io, int n, double beat_samples) override;

private:
    std::unique_ptr<PluginInstance> plugin_;
    bool ready_ = false;
    std::string error_;
};

}  // namespace sr
