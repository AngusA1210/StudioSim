#include "instruments.h"

namespace sr {
namespace {

// A free voice, or the one that has been playing longest.
template <typename V, size_t N>
V& pickVoice(std::array<V, N>& pool) {
    V* oldest = &pool[0];
    for (auto& v : pool) {
        if (!v.active) return v;
        if (v.t > oldest->t) oldest = &v;
    }
    return *oldest;
}

constexpr float kLowpassQ = 1.08f;  // the prototype's default Web Audio Q (1 dB) as a linear Q

}  // namespace

namespace voice {

// ── ToneHit ────────────────────────────────────────────────────────────────────────────────────────────────
void ToneHit::start(float sample_rate, int delay_samples, bool tri, float f0, float f1, float sweep_sec, float lvl,
                    float decay_sec) {
    sr = sample_rate;
    active = true;
    triangle = tri;
    delay = delay_samples;
    t = 0;
    phase = 0;
    freq = f0;
    freq_end = f1;
    sweep_len = int(sweep_sec * sr);
    freq_mul = expStep(f0, f1, float(sweep_len));
    level = std::max(lvl, 0.002f);
    amp = 0;
    attack_len = std::max(1, int(0.003f * sr));
    decay_mul = expStep(level, 0.001f, (decay_sec - 0.003f) * sr);
    end_len = int((decay_sec + 0.02f) * sr);
}

float ToneHit::next() {
    if (delay > 0) { --delay; return 0.0f; }
    if (t < attack_len) amp = level * float(t) / float(attack_len);
    else if (t == attack_len) amp = level;
    else amp *= decay_mul;
    const float s = triangle ? 1.0f - 4.0f * std::fabs(wrap01(phase + 0.25f) - 0.5f) : sineOf(phase);
    phase += freq / sr;
    if (phase >= 1.0f) phase -= 1.0f;
    freq = t < sweep_len ? freq * freq_mul : freq_end;
    if (++t >= end_len) active = false;
    return s * amp;
}

// ── NoiseHit ───────────────────────────────────────────────────────────────────────────────────────────────
void NoiseHit::start(float sample_rate, int delay_samples, Biquad::Type type, float freq, float q, float lvl,
                     float decay_sec) {
    active = true;
    delay = delay_samples;
    t = 0;
    filter.reset();
    filter.set(type, sample_rate, freq, q);
    amp = std::max(lvl, 0.002f);
    decay_mul = expStep(amp, 0.001f, decay_sec * sample_rate);
    end_len = int((decay_sec + 0.02f) * sample_rate);
}

float NoiseHit::next(Rng& rng) {
    if (delay > 0) { --delay; return 0.0f; }
    const float y = filter.process(rng.next()) * amp;
    amp *= decay_mul;
    if (++t >= end_len) active = false;
    return y;
}

// ── BassVoice: saw through a resonant low-pass that closes, plus a sine for weight ─────────────────────────
void BassVoice::start(float sample_rate, int delay_samples, float freq, float dur_sec, float velocity) {
    sr = sample_rate;
    active = true;
    delay = delay_samples;
    t = 0;
    v = velocity;
    amp = 0;
    attack_len = std::max(1, int(0.006f * sr));
    hold_len = std::max(attack_len + 1, int(dur_sec * sr));
    release_len = int(0.06f * sr);
    decay_mul = expStep(v, 0.6f * v, float(hold_len - attack_len));
    cutoff = 1500.0f;
    cutoff_len = int(0.2f * sr);
    cutoff_mul = expStep(1500.0f, 360.0f, float(cutoff_len));
    saw = SawOsc{};
    saw.setFreq(freq, sr);
    sine_phase = 0;
    sine_inc = freq / sr;
    lp.reset();
}

float BassVoice::next() {
    if (delay > 0) { --delay; return 0.0f; }
    if ((t & 15) == 0) lp.set(Biquad::Lowpass, sr, cutoff, 1.585f);
    cutoff = t < cutoff_len ? cutoff * cutoff_mul : 360.0f;
    if (t < attack_len) amp = v * float(t) / float(attack_len);
    else if (t == attack_len) amp = v;
    else if (t < hold_len) amp *= decay_mul;
    else if (t == hold_len) release_step = amp / float(release_len);
    else amp -= release_step;
    const float s = lp.process(saw.next() * 0.55f) + sineOf(sine_phase) * 0.6f;
    sine_phase += sine_inc;
    if (sine_phase >= 1.0f) sine_phase -= 1.0f;
    if (++t >= hold_len + release_len || amp < 0.0f) active = false;
    return s * std::max(amp, 0.0f);
}

// ── PadVoice: detuned saw pairs through a slowly opening low-pass ──────────────────────────────────────────
void PadVoice::start(float sample_rate, int delay_samples, const int* notes, int count, float dur_sec, float velocity,
                     Rng& rng) {
    sr = sample_rate;
    active = true;
    delay = delay_samples;
    t = 0;
    v = velocity;
    attack_len = int(0.5f * sr);
    hold_len = std::max(attack_len, int(dur_sec * sr));
    release_len = int(1.2f * sr);
    rise_len = std::max(1, int(0.55f * dur_sec * sr));
    fall_len = std::max(1, hold_len + release_len - rise_len);
    osc_count = 0;
    for (int i = 0; i < count && osc_count + 2 <= kMaxOscs; ++i) {
        for (float cents : {-8.0f, 8.0f}) {
            SawOsc& o = oscs[osc_count++];
            o.setFreq(mtof(float(notes[i])) * centsToRatio(cents), sr);
            o.phase = rng.uniform();
        }
    }
    cutoff = 600.0f;
    lp.reset();
}

float PadVoice::next() {
    if (delay > 0) { --delay; return 0.0f; }
    if ((t & 31) == 0) {
        cutoff = t < rise_len ? 600.0f + 1300.0f * float(t) / float(rise_len)
                              : 1900.0f - 1200.0f * float(t - rise_len) / float(fall_len);
        lp.set(Biquad::Lowpass, sr, cutoff, kLowpassQ);
    }
    float amp;
    if (t < attack_len) amp = v * float(t) / float(attack_len);
    else if (t < hold_len) amp = v;
    else amp = v * (1.0f - float(t - hold_len) / float(release_len));
    float s = 0;
    for (int i = 0; i < osc_count; ++i) s += oscs[i].next();
    if (++t >= hold_len + release_len) active = false;
    return lp.process(s) * std::max(amp, 0.0f);
}

// ── BellVoice ──────────────────────────────────────────────────────────────────────────────────────────────
void BellVoice::start(float sample_rate, int delay_samples, float freq, float velocity) {
    sr = sample_rate;
    active = true;
    delay = delay_samples;
    t = 0;
    f = freq;
    car_phase = mod_phase = 0;
    dev = 2.4f * f;
    dev_end = 0.2f * f;
    index_len = int(0.3f * sr);
    dev_mul = expStep(dev, dev_end, float(index_len));
    v = velocity;
    amp = 0;
    attack_len = std::max(1, int(0.003f * sr));
    decay_mul = expStep(v, 0.0001f, (1.2f - 0.003f) * sr);
    end_len = int(1.25f * sr);
}

float BellVoice::next() {
    if (delay > 0) { --delay; return 0.0f; }
    if (t < attack_len) amp = v * float(t) / float(attack_len);
    else if (t == attack_len) amp = v;
    else amp *= decay_mul;
    const float out = sineOf(car_phase) * amp;
    car_phase = wrap01(car_phase + (f + dev * sineOf(mod_phase)) / sr);
    mod_phase = wrap01(mod_phase + 3.5f * f / sr);
    dev = t < index_len ? dev * dev_mul : dev_end;
    if (++t >= end_len) active = false;
    return out;
}

// ── EPianoVoice ────────────────────────────────────────────────────────────────────────────────────────────
void EPianoVoice::start(float sample_rate, int midi_note, float velocity) {
    sr = sample_rate;
    active = true;
    released = false;
    note = midi_note;
    t = 0;
    f = mtof(float(midi_note));
    ph_a = ph_b = mod_phase = 0;
    dev = 1.5f * f;
    dev_end = 0.3f * f;
    index_len = int(0.6f * sr);
    dev_mul = expStep(dev, dev_end, float(index_len));
    amp = 0;
    peak = 0.42f * std::clamp(velocity / 0.8f, 0.05f, 1.25f);
    attack_len = std::max(1, int(0.002f * sr));
    hold_coef = tauCoef(0.9f, sr);
    release_coef = tauCoef(0.07f, sr);
}

float EPianoVoice::next() {
    if (released) {
        amp *= release_coef;
        if (amp < 1e-4f) { active = false; return 0.0f; }
    } else if (t < attack_len) {
        amp = peak * float(t) / float(attack_len);
    } else {
        const float sustain = peak * (0.1f / 0.42f);
        amp = sustain + (amp - sustain) * hold_coef;
    }
    static const float kDetuneLo = centsToRatio(-4.0f), kDetuneHi = centsToRatio(4.0f);
    const float m = dev * sineOf(mod_phase);
    const float out = (sineOf(ph_a) + sineOf(ph_b)) * amp;
    ph_a = wrap01(ph_a + (f * kDetuneLo + m) / sr);
    ph_b = wrap01(ph_b + (f * kDetuneHi + m) / sr);
    mod_phase = wrap01(mod_phase + f / sr);
    dev = t < index_len ? dev * dev_mul : dev_end;
    ++t;
    return out;
}

}  // namespace voice

// ── Instruments ────────────────────────────────────────────────────────────────────────────────────────────
voice::ToneHit& Drums::toneSlot() { return pickVoice(tones_); }
voice::NoiseHit& Drums::noiseSlot() { return pickVoice(noises_); }

void Drums::hit(Piece piece, float v, int delay) {
    switch (piece) {
        case Kick:
            toneSlot().start(sr_, delay, false, 150.0f, 48.0f, 0.085f, v, 0.38f);
            noiseSlot().start(sr_, delay, Biquad::Lowpass, 3500.0f, kLowpassQ, v * 0.45f, 0.018f);
            break;
        case Snare:
            noiseSlot().start(sr_, delay, Biquad::Bandpass, 2200.0f, 0.6f, v * 0.6f, 0.2f);
            noiseSlot().start(sr_, delay, Biquad::Highpass, 5000.0f, kLowpassQ, v * 0.3f, 0.08f);
            toneSlot().start(sr_, delay, true, 205.0f, 165.0f, 0.06f, v * 0.45f, 0.11f);
            break;
        case HatClosed:
        case HatOpen:
            noiseSlot().start(sr_, delay, Biquad::Highpass, 8000.0f, kLowpassQ, v * 0.34f, piece == HatOpen ? 0.3f : 0.07f);
            break;
    }
}

void Drums::render(float* out, int n) {
    for (auto& v : tones_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next();
    for (auto& v : noises_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next(rng_);
}

void Bass::play(int note, float dur_sec, float velocity, int delay) {
    pickVoice(voices_).start(sr_, delay, mtof(float(note)), dur_sec, velocity);
}

void Bass::render(float* out, int n) {
    for (auto& v : voices_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next();
}

void Pad::play(const int* notes, int count, float dur_sec, float velocity, int delay) {
    pickVoice(voices_).start(sr_, delay, notes, count, dur_sec, velocity, rng_);
}

void Pad::render(float* out, int n) {
    for (auto& v : voices_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next();
}

void Bells::play(int note, float velocity, int delay) {
    pickVoice(voices_).start(sr_, delay, mtof(float(note)), velocity);
}

void Bells::render(float* out, int n) {
    for (auto& v : voices_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next();
}

void Keys::noteOn(int note, float velocity) {
    noteOff(note);  // retrigger rather than stack the same key
    pickVoice(voices_).start(sr_, note, velocity);
}

void Keys::noteOff(int note) {
    for (auto& v : voices_)
        if (v.active && !v.released && v.note == note) v.release();
}

void Keys::allNotesOff() {
    for (auto& v : voices_)
        if (v.active) v.release();
}

void Keys::render(float* out, int n) {
    for (auto& v : voices_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next();
}

}  // namespace sr
