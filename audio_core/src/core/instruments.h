#pragma once

// Synthesized instruments, ported from the browser prototype. Every voice is pre-allocated, so nothing here
// allocates on the audio thread. Each instrument can be played two ways: live (noteOn/noteOff, from the computer
// keyboard or a MIDI controller) and by the sequencer (play), where a note has a set length and can start partway
// into a block (`delay` samples), which is what makes the sequencer sample-accurate.

#include <array>
#include <cstdint>
#include <vector>

#include "dsp.h"

namespace sr {

enum class InstrumentKind : uint8_t { Drums, Bass, Pad, Bells, Keys, Live };
constexpr int kInstrumentKinds = 6;

class Instrument {
public:
    explicit Instrument(float sample_rate) : sr_(sample_rate) {}
    virtual ~Instrument() = default;

    // Adds the next `n` samples of this instrument into `out` (mono).
    virtual void render(float* out, int n) = 0;

    // Played live. The note sounds from the start of the next block.
    virtual void noteOn(int /*note*/, float /*velocity*/) {}
    virtual void noteOff(int /*note*/) {}
    virtual void sustain(bool /*pedal_down*/) {}
    virtual void allNotesOff() {}  // releases everything that is being played live

    // Played by the sequencer: a note `dur_sec` long that starts `delay` samples into the coming block.
    virtual void play(int /*note*/, float /*dur_sec*/, float /*velocity*/, int /*delay*/) {}
    virtual void stopSequenced() {}  // fades out whatever the sequencer started
    // How much the loudness of each sequenced note varies, so a repeated note doesn't sound mechanical.
    virtual float velocityJitter() const { return 0.0f; }

    virtual void setInputChannel(int /*channel*/) {}  // live input only
    virtual void setInputEnabled(bool /*on*/) {}      // live input only

protected:
    float sr_;
};

namespace voice {

// Oscillator with an exponential pitch drop and a percussive envelope (kick body, snare tone).
struct ToneHit {
    bool active = false, triangle = false;
    int delay = 0, t = 0, attack_len = 0, sweep_len = 0, end_len = 0;
    float phase = 0, freq = 0, freq_mul = 1, freq_end = 0, amp = 0, level = 0, decay_mul = 1, sr = 48000;

    void start(float sample_rate, int delay_samples, bool tri, float f0, float f1, float sweep_sec, float lvl, float decay_sec);
    float next();
};

// Filtered noise burst with an exponential decay (kick click, snare wires, hats).
struct NoiseHit {
    bool active = false;
    int delay = 0, t = 0, end_len = 0;
    float amp = 0, decay_mul = 1;
    Biquad filter;

    void start(float sample_rate, int delay_samples, Biquad::Type type, float freq, float q, float lvl, float decay_sec);
    float next(Rng& rng);
};

struct BassVoice {
    bool active = false, live = false;
    int note = -1, delay = 0, t = 0, attack_len = 0, hold_len = 0, release_len = 0, cutoff_len = 0;
    float sr = 48000, v = 0, amp = 0, decay_mul = 1, release_step = 0, cutoff = 0, cutoff_mul = 1;
    float sine_phase = 0, sine_inc = 0;
    SawOsc saw;
    Biquad lp;

    // dur_sec < 0: played live, so it holds (slowly dying away) until release().
    void start(float sample_rate, int delay_samples, int midi_note, float dur_sec, float velocity);
    void release();
    float next();
};

// One note of the pad: a detuned pair of saws through a low-pass that opens slowly and closes again.
struct PadVoice {
    bool active = false, live = false, released = false;
    int note = -1, delay = 0, t = 0, attack_len = 0, hold_len = 0, release_len = 0;
    int rise_len = 0, fall_start = -1, fall_len = 1, release_start = 0, release_span = 1;
    float sr = 48000, v = 0, amp = 0, release_from = 0, cutoff = 600, fall_from = 1900;
    std::array<SawOsc, 2> oscs;
    Biquad lp;

    // dur_sec < 0: played live, so it holds until release().
    void start(float sample_rate, int delay_samples, int midi_note, float dur_sec, float velocity, Rng& rng);
    void release();
    float next();
};

// Two-operator FM with an inharmonic ratio and a fast-decaying index: a soft bell.
struct BellVoice {
    bool active = false;
    int delay = 0, t = 0, attack_len = 0, index_len = 0, end_len = 0;
    float sr = 48000, f = 0, car_phase = 0, mod_phase = 0, dev = 0, dev_mul = 1, dev_end = 0, v = 0, amp = 0, decay_mul = 1;

    void start(float sample_rate, int delay_samples, float freq, float velocity);
    float next();
};

// The keys: 1:1 FM electric piano, two slightly detuned carriers. Sustains while held.
struct EPianoVoice {
    bool active = false, released = false, pedal_held = false, live = true;
    int note = -1, delay = 0, t = 0, attack_len = 0, index_len = 0, release_at = -1;
    float sr = 48000, f = 0, ph_a = 0, ph_b = 0, mod_phase = 0, dev = 0, dev_mul = 1, dev_end = 0;
    float amp = 0, peak = 0, hold_coef = 1, release_coef = 1;

    // release_after < 0: played live, so it holds until release().
    void start(float sample_rate, int midi_note, float velocity, int delay_samples = 0, int release_after = -1);
    void release() { released = true; }
    float next();
};

}  // namespace voice

// A drum machine. Every note plays one of its pieces, laid out like the General MIDI drum map and repeated in
// every octave, so any key on a controller does something.
class Drums : public Instrument {
public:
    enum Piece { Kick, Snare, HatClosed, HatOpen, TomLow, TomHigh, Clap, Crash, kPieces };
    static Piece pieceFor(int note);
    static int noteFor(Piece piece);  // the note a piece is written as in a pattern
    static const char* pieceName(Piece piece);

    using Instrument::Instrument;
    void hit(Piece piece, float velocity, int delay);
    void noteOn(int note, float velocity) override { hit(pieceFor(note), velocity, 0); }
    void play(int note, float /*dur_sec*/, float velocity, int delay) override { hit(pieceFor(note), velocity, delay); }
    void render(float* out, int n) override;

private:
    voice::ToneHit& toneSlot();
    voice::NoiseHit& noiseSlot();
    std::array<voice::ToneHit, 12> tones_;
    std::array<voice::NoiseHit, 24> noises_;
    Rng rng_;
};

class Bass : public Instrument {
public:
    using Instrument::Instrument;
    void noteOn(int note, float velocity) override;
    void noteOff(int note) override;
    void allNotesOff() override;
    void play(int note, float dur_sec, float velocity, int delay) override;
    void stopSequenced() override;
    void render(float* out, int n) override;

private:
    std::array<voice::BassVoice, 6> voices_;
};

class Pad : public Instrument {
public:
    using Instrument::Instrument;
    void noteOn(int note, float velocity) override;
    void noteOff(int note) override;
    void allNotesOff() override;
    void play(int note, float dur_sec, float velocity, int delay) override;
    void stopSequenced() override;
    void render(float* out, int n) override;

private:
    std::array<voice::PadVoice, 20> voices_;
    Rng rng_{0x2545F491u};
};

class Bells : public Instrument {
public:
    using Instrument::Instrument;
    void noteOn(int note, float velocity) override { strike(note, velocity, 0); }
    void play(int note, float /*dur_sec*/, float velocity, int delay) override { strike(note, velocity, delay); }
    float velocityJitter() const override { return 0.1f; }
    void render(float* out, int n) override;

private:
    void strike(int note, float velocity, int delay);
    std::array<voice::BellVoice, 12> voices_;
};

class Keys : public Instrument {
public:
    using Instrument::Instrument;
    void noteOn(int note, float velocity) override;
    void noteOff(int note) override;
    void sustain(bool pedal_down) override;
    void allNotesOff() override;
    void play(int note, float dur_sec, float velocity, int delay) override;
    void stopSequenced() override;
    void render(float* out, int n) override;

private:
    std::array<voice::EPianoVoice, 24> voices_;
    bool pedal_ = false;
};

// The audio captured for the block being rendered, one buffer per hardware input. Owned by the engine.
struct InputBus {
    static constexpr int kMaxChannels = 8;
    std::array<std::vector<float>, kMaxChannels> channel;
    int active = 0;  // how many inputs the open device delivers
};

// Whatever is plugged into the audio input (a microphone, a guitar), placed in the room like any instrument.
// It plays one hardware input, or all of them added together.
class LiveInput : public Instrument {
public:
    static constexpr int kAllInputs = -1;
    LiveInput(float sample_rate, const InputBus* bus) : Instrument(sample_rate), bus_(bus) {}
    void setInputChannel(int channel) override { channel_ = channel; }
    void setInputEnabled(bool on) override { enabled_ = on; }  // off: silent, whatever comes in
    void render(float* out, int n) override {
        if (!bus_ || !enabled_) return;
        const int first = channel_ < 0 ? 0 : channel_, last = channel_ < 0 ? bus_->active : channel_ + 1;
        for (int c = first; c < last && c < bus_->active; ++c) {
            const float* in = bus_->channel[size_t(c)].data();
            for (int i = 0; i < n; ++i) out[i] += in[i];
        }
    }

private:
    const InputBus* bus_;
    int channel_ = kAllInputs;
    bool enabled_ = false;
};

}  // namespace sr
