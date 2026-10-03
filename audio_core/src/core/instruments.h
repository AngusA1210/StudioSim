#pragma once

// Synthesized instruments, ported from the browser prototype. Every voice is pre-allocated, so nothing here
// allocates on the audio thread. A voice can start partway into a block (`delay` samples), which is what makes
// the sequencer sample-accurate.

#include <array>
#include <cstdint>

#include "dsp.h"

namespace sr {

enum class InstrumentKind : uint8_t { Drums, Bass, Pad, Bells, Keys };

class Instrument {
public:
    explicit Instrument(float sample_rate) : sr_(sample_rate) {}
    virtual ~Instrument() = default;

    // Adds the next `n` samples of this instrument into `out` (mono).
    virtual void render(float* out, int n) = 0;

    // Live playing. Instruments that only follow the sequencer ignore these.
    virtual void noteOn(int /*note*/, float /*velocity*/) {}
    virtual void noteOff(int /*note*/) {}
    virtual void allNotesOff() {}

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
    bool active = false;
    int delay = 0, t = 0, attack_len = 0, hold_len = 0, release_len = 0, cutoff_len = 0;
    float sr = 48000, v = 0, amp = 0, decay_mul = 1, release_step = 0, cutoff = 0, cutoff_mul = 1;
    float sine_phase = 0, sine_inc = 0;
    SawOsc saw;
    Biquad lp;

    void start(float sample_rate, int delay_samples, float freq, float dur_sec, float velocity);
    float next();
};

struct PadVoice {
    static constexpr int kMaxOscs = 8;
    bool active = false;
    int delay = 0, t = 0, attack_len = 0, hold_len = 0, release_len = 0, rise_len = 0, fall_len = 0, osc_count = 0;
    float sr = 48000, v = 0, cutoff = 0;
    std::array<SawOsc, kMaxOscs> oscs;
    Biquad lp;

    void start(float sample_rate, int delay_samples, const int* notes, int count, float dur_sec, float velocity, Rng& rng);
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

// The playable keys: 1:1 FM electric piano, two slightly detuned carriers. Sustains while held.
struct EPianoVoice {
    bool active = false, released = false;
    int note = -1, t = 0, attack_len = 0, index_len = 0;
    float sr = 48000, f = 0, ph_a = 0, ph_b = 0, mod_phase = 0, dev = 0, dev_mul = 1, dev_end = 0;
    float amp = 0, peak = 0, hold_coef = 1, release_coef = 1;

    void start(float sample_rate, int midi_note, float velocity);
    void release() { released = true; }
    float next();
};

}  // namespace voice

class Drums : public Instrument {
public:
    enum Piece { Kick, Snare, HatClosed, HatOpen };
    using Instrument::Instrument;
    void hit(Piece piece, float velocity, int delay);
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
    void play(int note, float dur_sec, float velocity, int delay);
    void render(float* out, int n) override;

private:
    std::array<voice::BassVoice, 4> voices_;
};

class Pad : public Instrument {
public:
    using Instrument::Instrument;
    void play(const int* notes, int count, float dur_sec, float velocity, int delay);
    void render(float* out, int n) override;

private:
    std::array<voice::PadVoice, 3> voices_;
    Rng rng_{0x2545F491u};
};

class Bells : public Instrument {
public:
    using Instrument::Instrument;
    void play(int note, float velocity, int delay);
    void render(float* out, int n) override;

private:
    std::array<voice::BellVoice, 12> voices_;
};

class Keys : public Instrument {
public:
    using Instrument::Instrument;
    void noteOn(int note, float velocity) override;
    void noteOff(int note) override;
    void allNotesOff() override;
    void render(float* out, int n) override;

private:
    std::array<voice::EPianoVoice, 16> voices_;
};

}  // namespace sr
