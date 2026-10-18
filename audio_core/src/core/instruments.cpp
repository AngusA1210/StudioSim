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
constexpr int kHeld = 1 << 30;      // a note length that never arrives: the note lasts until it is released
constexpr float kPadLevel = 0.0875f;  // a velocity of 0.8 gives each pad note the prototype's level
constexpr float kMinVelocity = 0.01f;

// Lets go of a sequenced voice: one that hasn't started yet is dropped, one that is sounding is released.
template <typename V>
void stopVoice(V& v) {
    if (!v.active || v.live) return;
    if (v.delay > 0) v.active = false;
    else v.release();
}

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

// ── ModeHit ────────────────────────────────────────────────────────────────────────────────────────────────
void ModeHit::start(float sample_rate, int delay_samples, float f_end, float sharp, float glide_sec, float lvl, float decay_sec) {
    sr = sample_rate;
    active = true;
    delay = delay_samples;
    t = 0;
    phase = 0;
    freq_end = f_end;
    freq = f_end * sharp;
    glide_mul = std::exp(-1.0f / std::max(glide_sec * sr, 1.0f));
    level = std::max(lvl, 0.0005f);
    amp = level;
    attack_len = std::max(1, int(0.0007f * sr));  // the stick's contact: a click without being one
    decay_mul = expStep(1.0f, 0.001f, decay_sec * sr);
    end_len = int((decay_sec + 0.01f) * sr);
}

float ModeHit::next() {
    if (delay > 0) { --delay; return 0.0f; }
    const float env = t < attack_len ? amp * float(t) / float(attack_len) : amp;
    amp *= decay_mul;
    const float s = sineOf(phase) * env;
    phase += freq / sr;
    if (phase >= 1.0f) phase -= 1.0f;
    freq = freq_end + (freq - freq_end) * glide_mul;
    if (++t >= end_len) active = false;
    return s;
}

// ── MetalHit ───────────────────────────────────────────────────────────────────────────────────────────────
void MetalHit::start(float sample_rate, int delay_samples, float base, float band_freq, float high_freq, float lvl, float decay_sec,
                     float noise_share, int grp) {
    // The ratios of an analog cymbal's six oscillators: none a simple multiple of another, so they clash.
    static constexpr float kRatios[6] = {1.0f, 1.4828f, 1.8004f, 2.5462f, 2.6304f, 3.8968f};
    sr = sample_rate;
    active = true;
    delay = delay_samples;
    t = 0;
    group = grp;
    for (int i = 0; i < 6; ++i) {
        phase[size_t(i)] = float(i) * 0.37f;
        inc[size_t(i)] = base * kRatios[i] / sr;
    }
    band.reset();
    band.set(Biquad::Bandpass, sr, band_freq, 0.9f);
    high.reset();
    high.set(Biquad::Highpass, sr, high_freq, 0.8f);
    amp = std::max(lvl, 0.0005f);
    noise = noise_share;
    decay_mul = expStep(1.0f, 0.001f, decay_sec * sr);
    end_len = int((decay_sec + 0.01f) * sr);
}

void MetalHit::choke(float decay_sec) {
    if (!active) return;
    decay_mul = expStep(1.0f, 0.001f, decay_sec * sr);
    end_len = std::min(end_len, t + int((decay_sec + 0.01f) * sr));
}

void MetalHit::restrike(float lvl, float decay_sec) {
    amp = std::sqrt(amp * amp + lvl * lvl);
    decay_mul = expStep(1.0f, 0.001f, decay_sec * sr);
    t = 0;
    end_len = int((decay_sec + 0.01f) * sr);
}

float MetalHit::next(Rng& rng) {
    if (delay > 0) { --delay; return 0.0f; }
    float square = 0.0f;
    for (int i = 0; i < 6; ++i) {
        float& p = phase[size_t(i)];
        square += p < 0.5f ? 1.0f : -1.0f;
        p += inc[size_t(i)];
        if (p >= 1.0f) p -= 1.0f;
    }
    const float x = square * (1.0f - noise) / 6.0f + rng.next() * noise;
    const float y = high.process(band.process(x)) * amp;
    amp *= decay_mul;
    if (++t >= end_len) active = false;
    return y;
}

// ── BassVoice: saw through a resonant low-pass that closes, plus a sine for weight ─────────────────────────
void BassVoice::start(float sample_rate, int delay_samples, int midi_note, float dur_sec, float velocity) {
    const float freq = mtof(float(midi_note));
    sr = sample_rate;
    active = true;
    live = dur_sec < 0.0f;
    note = midi_note;
    delay = delay_samples;
    t = 0;
    v = std::max(velocity, kMinVelocity);
    amp = 0;
    release_step = 0;
    attack_len = std::max(1, int(0.006f * sr));
    release_len = int(0.06f * sr);
    if (live) {  // dies away like a held string: down to 60 % after two seconds
        hold_len = kHeld;
        decay_mul = expStep(v, 0.6f * v, 2.0f * sr);
    } else {
        hold_len = std::max(attack_len + 1, int(dur_sec * sr));
        decay_mul = expStep(v, 0.6f * v, float(hold_len - attack_len));
    }
    cutoff = 1500.0f;
    cutoff_len = int(0.2f * sr);
    cutoff_mul = expStep(1500.0f, 360.0f, float(cutoff_len));
    saw = SawOsc{};
    saw.setFreq(freq, sr);
    sine_phase = 0;
    sine_inc = freq / sr;
    lp.reset();
}

void BassVoice::release() {
    if (t < hold_len) hold_len = std::max(t, attack_len + 1);  // the release starts at the next sample
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

// ── PadVoice: a detuned saw pair through a slowly opening low-pass ─────────────────────────────────────────
void PadVoice::start(float sample_rate, int delay_samples, int midi_note, float dur_sec, float velocity, Rng& rng) {
    sr = sample_rate;
    active = true;
    live = dur_sec < 0.0f;
    released = false;
    note = midi_note;
    delay = delay_samples;
    t = 0;
    v = std::max(velocity, kMinVelocity) * kPadLevel;
    amp = 0;
    release_len = int(1.2f * sr);
    if (live) {  // speaks sooner than the sequenced chords, and the filter stays open while the key is down
        attack_len = int(0.12f * sr);
        hold_len = -1;
        rise_len = int(0.8f * sr);
        fall_start = -1;
        fall_len = release_len;
    } else {
        attack_len = int(0.5f * sr);
        hold_len = std::max(attack_len, int(dur_sec * sr));
        rise_len = std::max(1, int(0.55f * dur_sec * sr));
        fall_start = rise_len;
        fall_len = std::max(1, hold_len + release_len - rise_len);
    }
    fall_from = 1900.0f;
    for (float cents : {-8.0f, 8.0f}) {
        SawOsc& o = oscs[cents < 0.0f ? 0 : 1];
        o.setFreq(mtof(float(midi_note)) * centsToRatio(cents), sr);
        o.phase = rng.uniform();
    }
    cutoff = 600.0f;
    lp.reset();
}

void PadVoice::release() {
    if (released) return;
    released = true;
    // A sequenced note that is cut short (the sequence was stopped) fades quickly; otherwise the usual long tail.
    const bool cut_short = !live && t < hold_len;
    release_from = amp;
    release_start = t;
    release_span = cut_short ? std::max(1, int(0.12f * sr)) : release_len;
    if (amp <= 0.0f) active = false;  // let go before it made a sound
    if (live) {  // close the filter from wherever it has got to
        rise_len = std::min(rise_len, t);
        fall_start = t;
        fall_from = cutoff;
    }
}

float PadVoice::next() {
    if (delay > 0) { --delay; return 0.0f; }
    if ((t & 31) == 0) {
        if (t < rise_len) cutoff = 600.0f + 1300.0f * float(t) / float(rise_len);
        else if (fall_start < 0) cutoff = 1900.0f;
        else cutoff = std::max(700.0f, fall_from - (fall_from - 700.0f) * float(t - fall_start) / float(fall_len));
        lp.set(Biquad::Lowpass, sr, cutoff, kLowpassQ);
    }
    if (!released) {
        amp = t < attack_len ? v * float(t) / float(attack_len) : v;
        if (hold_len >= 0 && t >= hold_len) release();
    } else {
        if (t - release_start >= release_span) { active = false; return 0.0f; }
        amp = release_from * (1.0f - float(t - release_start) / float(release_span));
    }
    const float s = oscs[0].next() + oscs[1].next();
    ++t;
    return lp.process(s) * amp;
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
    v = std::max(velocity, kMinVelocity);
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
void EPianoVoice::start(float sample_rate, int midi_note, float velocity, int delay_samples, int release_after) {
    sr = sample_rate;
    active = true;
    released = false;
    pedal_held = false;
    live = release_after < 0;
    note = midi_note;
    delay = delay_samples;
    release_at = release_after;
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
    if (delay > 0) { --delay; return 0.0f; }
    if (release_at >= 0 && t >= release_at) released = true;
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
Drums::Piece Drums::pieceFor(int note) {
    // C kick, D and E snare, F and G low tom, A and B high tom; C# crash, D# clap, F# and G# closed hat, A# open hat.
    static const Piece kMap[12] = {Kick, Crash, Snare, Clap, Snare, TomLow, HatClosed, TomLow, HatClosed, TomHigh, HatOpen, TomHigh};
    return kMap[((note % 12) + 12) % 12];
}

int Drums::noteFor(Piece piece) {
    static const int kNote[kPieces] = {36, 38, 42, 46, 41, 45, 39, 49};
    return kNote[piece];
}

const char* Drums::pieceName(Piece piece) {
    static const char* const kName[kPieces] = {"Kick", "Snare", "Closed hat", "Open hat", "Low tom", "High tom", "Clap", "Crash"};
    return kName[piece];
}

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
        case TomLow:
        case TomHigh: {
            const bool low = piece == TomLow;
            toneSlot().start(sr_, delay, false, low ? 130.0f : 205.0f, low ? 84.0f : 140.0f, 0.11f, v * 0.75f, low ? 0.34f : 0.26f);
            noiseSlot().start(sr_, delay, Biquad::Lowpass, low ? 1400.0f : 2200.0f, kLowpassQ, v * 0.16f, 0.025f);
            break;
        }
        case Clap:  // three quick bursts, then the tail
            for (int i = 0; i < 3; ++i)
                noiseSlot().start(sr_, delay + int(0.011f * float(i) * sr_), Biquad::Bandpass, 1500.0f, 1.2f, v * 0.5f, 0.012f);
            noiseSlot().start(sr_, delay + int(0.033f * sr_), Biquad::Bandpass, 1500.0f, 1.2f, v * 0.55f, 0.16f);
            break;
        case Crash:
            noiseSlot().start(sr_, delay, Biquad::Highpass, 5200.0f, kLowpassQ, v * 0.3f, 1.1f);
            noiseSlot().start(sr_, delay, Biquad::Bandpass, 9500.0f, 2.0f, v * 0.25f, 0.35f);
            break;
        case kPieces:
            break;
    }
}

void Drums::render(float* out, int n) {
    for (auto& v : tones_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next();
    for (auto& v : noises_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next(rng_);
}

// ── The acoustic kits ──────────────────────────────────────────────────────────────────────────────────────
namespace {

// kick: Hz, sharp, decay, boom, beater · snare: Hz, decay, ring, ring decay, wires, wire decay ·
// toms: rack Hz, floor Hz, rack decay, floor decay, sharp · hats' noise, hats' band, cymbals' noise ·
// buzz · tune and level jitter · drive · room
constexpr KitVoicing kGarage{54.0f, 2.3f, 0.95f, 0.30f, 0.34f,
                             190.0f, 0.24f, 0.11f, 0.65f, 0.50f, 0.34f,
                             136.0f, 85.0f, 1.0f, 1.45f, 0.10f,
                             0.50f, 8500.0f, 0.65f,
                             0.07f, 0.012f, 0.08f, 1.6f, 0.34f};
constexpr KitVoicing kStudio{50.0f, 1.9f, 0.42f, 0.08f, 0.48f,
                             212.0f, 0.15f, 0.025f, 0.25f, 0.40f, 0.20f,
                             146.0f, 96.0f, 0.55f, 0.80f, 0.06f,
                             0.22f, 10000.0f, 0.42f,
                             0.02f, 0.005f, 0.04f, 1.0f, 0.0f};

// The garage's first reflections: walls, floor and ceiling a few metres off, in milliseconds, and how loud each comes back.
constexpr float kEchoMs[5] = {3.7f, 6.1f, 9.4f, 12.8f, 17.5f};
constexpr float kEchoGain[5] = {0.55f, 0.45f, 0.36f, 0.28f, 0.2f};

}  // namespace

GarageKit::GarageKit(float sample_rate) : AcousticKit(sample_rate, kGarage) {}
StudioKit::StudioKit(float sample_rate) : AcousticKit(sample_rate, kStudio) {}

AcousticKit::AcousticKit(float sample_rate, const KitVoicing& voicing)
    : Instrument(sample_rate), v_(voicing), scratch_(8192, 0.0f), echoes_(size_t(0.02f * sample_rate) + 1, 0.0f) {}

int AcousticKit::noteFor(Piece piece) { return piece == Ride ? 51 : Drums::noteFor(piece); }

const char* AcousticKit::pieceName(Piece piece) { return piece == Ride ? "Ride" : Drums::pieceName(piece); }

void AcousticKit::mode(int delay, float freq, float sharp, float glide, float level, float decay) {
    pickVoice(modes_).start(sr_, delay, freq, sharp, glide, level, decay);
}

void AcousticKit::noise(int delay, Biquad::Type type, float freq, float q, float level, float decay) {
    pickVoice(noises_).start(sr_, delay, type, freq, q, level, decay);
}

void AcousticKit::metal(int delay, float base, float band, float high, float level, float decay, float noise_share, int group) {
    pickVoice(metals_).start(sr_, delay, base, band, high, level, decay, noise_share, group);
}

void AcousticKit::wash(voice::MetalHit& ring, int delay, float base, float band, float high, float level, float decay, float noise_share) {
    if (ring.active && ring.delay == 0) ring.restrike(level, decay);
    else ring.start(sr_, delay, base, band, high, level, decay, noise_share, 0);
}

void AcousticKit::hit(Piece piece, float velocity, int delay) {
    const KitVoicing& k = v_;
    const float v = std::clamp(velocity, 0.0f, 1.0f);
    const float bright = 0.55f + 0.45f * v;                    // harder hits are brighter...
    const float tune = 1.0f + k.tune_jitter * rng_.next();      // ...and no two land quite the same
    const float l = v * (1.0f + k.level_jitter * rng_.next());
    const auto buzz = [&](float decay) {  // the snare's wires, set going by whatever else is hit
        noise(delay, Biquad::Bandpass, 3800.0f, 0.6f, k.buzz * l, decay);
    };
    switch (piece) {
        case Drums::Kick:
            mode(delay, k.kick_hz * tune, k.kick_sharp, 0.012f, 0.95f * l, k.kick_decay);
            mode(delay, k.kick_hz * 1.78f * tune, 1.15f, 0.02f, k.kick_boom * l, k.kick_decay * 0.45f);
            mode(delay, k.kick_hz * 3.1f * tune, 1.05f, 0.02f, 0.10f * l, 0.16f);
            noise(delay, Biquad::Bandpass, 2600.0f * bright, 0.8f, k.kick_beater * l * bright, 0.03f);  // the beater
            noise(delay, Biquad::Lowpass, 900.0f, kLowpassQ, 0.28f * l, 0.05f);
            buzz(0.22f);
            break;
        case Drums::Snare: {
            const float f = k.snare_hz * tune;
            mode(delay, f, 1.04f, 0.03f, 0.42f * l, k.snare_decay);
            mode(delay, f * 1.59f, 1.04f, 0.03f, 0.30f * l, k.snare_decay * 0.75f);
            mode(delay, f * 2.14f, 1.03f, 0.03f, 0.20f * l, k.snare_decay * 0.6f);
            mode(delay, f * 2.30f, 1.03f, 0.03f, 0.14f * l, k.snare_decay * 0.5f);
            mode(delay, f * 2.72f, 1.0f, 0.01f, k.snare_ring * l, k.snare_ring_decay);  // the ring a head keeps
            mode(delay, 890.0f * tune, 1.0f, 0.01f, 0.07f * l, 0.06f);                 // the shell
            noise(delay, Biquad::Bandpass, 2500.0f + 4500.0f * v, 0.5f, 0.6f * l * bright * bright, 0.012f);  // the stick
            // The wires: brighter, as the stick is, the harder the head is hit.
            noise(delay, Biquad::Bandpass, 3000.0f + 1800.0f * v, 0.6f, k.snare_wires * l, k.snare_wire_decay);
            noise(delay, Biquad::Highpass, 6500.0f, 0.7f, 0.20f * l * bright * bright, k.snare_wire_decay * 0.5f);
            noise(delay, Biquad::Bandpass, 2400.0f, 1.0f, 0.08f * l, k.snare_wire_decay * 1.3f);
            break;
        }
        case Drums::TomLow:
        case Drums::TomHigh: {
            const bool floor = piece == Drums::TomLow;
            const float f = (floor ? k.floor_hz : k.rack_hz) * tune;
            const float sharp = 1.04f + k.tom_sharp * v;  // a hard hit stretches the head more, so it starts sharper
            const float ring = floor ? k.floor_decay : k.rack_decay;
            mode(delay, f, sharp, 0.05f, 0.80f * l, ring);
            mode(delay, f * 1.59f, sharp, 0.05f, 0.34f * l, ring * 0.5f);
            mode(delay, f * 2.14f, sharp, 0.05f, 0.16f * l, ring * 0.3f);
            mode(delay, f * 2.65f, sharp, 0.05f, 0.07f * l, ring * 0.18f);
            noise(delay, Biquad::Bandpass, 1800.0f * bright, 0.8f, 0.24f * l * bright, 0.025f);
            buzz(0.25f);
            break;
        }
        case Drums::HatClosed:
        case Drums::HatOpen: {
            const bool open = piece == Drums::HatOpen;
            if (!open)
                for (auto& m : metals_)
                    if (m.active && m.group == 1) m.choke(0.04f);
            metal(delay, 412.0f * tune, k.hat_band, 6200.0f, 0.55f * l * bright, open ? 0.75f : 0.075f, k.hat_noise, 1);
            noise(delay, Biquad::Bandpass, 3200.0f, 1.2f, 0.18f * l, 0.008f);  // the stick's tick
            break;
        }
        case Ride:  // a ping on top of a wash that builds and hangs
            metal(delay, 523.0f * tune, 5200.0f, 3000.0f, 0.30f * l * bright, 0.4f, 0.15f, 0);
            wash(ride_wash_, delay, 391.0f, 7000.0f, 4200.0f, 0.13f * l, 5.0f, k.cymbal_noise * 0.85f);
            mode(delay, 3150.0f * tune, 1.0f, 0.01f, 0.05f * l, 1.2f);
            noise(delay, Biquad::Bandpass, 3600.0f, 1.5f, 0.12f * l, 0.01f);
            break;
        case Drums::Crash:
            wash(crash_wash_, delay, 347.0f, 6500.0f, 3200.0f, 0.42f * l * bright, 3.5f, k.cymbal_noise);
            noise(delay, Biquad::Highpass, 4500.0f, 0.7f, 0.22f * l * bright, 2.8f);
            noise(delay, Biquad::Bandpass, 2000.0f, 0.8f, 0.12f * l, 0.05f);
            break;
        case Drums::kPieces:
            break;
    }
}

void AcousticKit::render(float* out, int n) {
    float* x = scratch_.data();
    for (int start = 0; start < n; start += int(scratch_.size())) {
        const int len = std::min(n - start, int(scratch_.size()));
        std::fill(x, x + len, 0.0f);
        for (auto& v : modes_)
            if (v.active) for (int i = 0; i < len && v.active; ++i) x[i] += v.next();
        for (auto& v : noises_)
            if (v.active) for (int i = 0; i < len && v.active; ++i) x[i] += v.next(rng_);
        for (auto& v : metals_)
            if (v.active) for (int i = 0; i < len && v.active; ++i) x[i] += v.next(rng_);
        for (auto* ring : {&ride_wash_, &crash_wash_})
            if (ring->active) for (int i = 0; i < len && ring->active; ++i) x[i] += ring->next(rng_);
        const size_t size = echoes_.size();
        for (int i = 0; i < len; ++i) {
            float y = x[i];
            if (v_.room > 0.0f) {  // the walls answering
                echoes_[echo_at_] = y;
                float back = 0.0f;
                for (int e = 0; e < 5; ++e) {
                    const size_t ago = std::min(size - 1, size_t(kEchoMs[e] * 0.001f * sr_));
                    back += kEchoGain[e] * echoes_[(echo_at_ + size - ago) % size];
                }
                echo_at_ = (echo_at_ + 1) % size;
                y += v_.room * back;
            }
            if (v_.drive > 1.0f) y = std::tanh(y * v_.drive) / v_.drive;  // as it was: quiet hits untouched, loud ones crunch
            out[start + i] += y;
        }
    }
}

void Bass::noteOn(int note, float velocity) {
    for (auto& v : voices_)  // retrigger rather than stack the same key
        if (v.active && v.live && v.note == note) v.release();
    pickVoice(voices_).start(sr_, 0, note, -1.0f, velocity);
}

void Bass::noteOff(int note) {
    for (auto& v : voices_)
        if (v.active && v.live && v.note == note) v.release();
}

void Bass::allNotesOff() {
    for (auto& v : voices_)
        if (v.active && v.live) v.release();
}

void Bass::play(int note, float dur_sec, float velocity, int delay) {
    pickVoice(voices_).start(sr_, delay, note, std::max(dur_sec, 0.0f), velocity);
}

void Bass::stopSequenced() {
    for (auto& v : voices_) stopVoice(v);
}

void Bass::render(float* out, int n) {
    for (auto& v : voices_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next();
}

void Pad::noteOn(int note, float velocity) {
    for (auto& v : voices_)
        if (v.active && v.live && v.note == note) v.release();
    pickVoice(voices_).start(sr_, 0, note, -1.0f, velocity, rng_);
}

void Pad::noteOff(int note) {
    for (auto& v : voices_)
        if (v.active && v.live && v.note == note) v.release();
}

void Pad::allNotesOff() {
    for (auto& v : voices_)
        if (v.active && v.live) v.release();
}

void Pad::play(int note, float dur_sec, float velocity, int delay) {
    pickVoice(voices_).start(sr_, delay, note, std::max(dur_sec, 0.0f), velocity, rng_);
}

void Pad::stopSequenced() {
    for (auto& v : voices_) stopVoice(v);
}

void Pad::render(float* out, int n) {
    for (auto& v : voices_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next();
}

void Bells::strike(int note, float velocity, int delay) {
    pickVoice(voices_).start(sr_, delay, mtof(float(note)), velocity);
}

void Bells::render(float* out, int n) {
    for (auto& v : voices_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next();
}

void Keys::noteOn(int note, float velocity) {
    for (auto& v : voices_)  // retrigger rather than stack the same key
        if (v.active && v.live && !v.released && v.note == note) v.release();
    pickVoice(voices_).start(sr_, note, velocity);
}

void Keys::noteOff(int note) {
    for (auto& v : voices_) {
        if (!v.active || !v.live || v.released || v.note != note) continue;
        if (pedal_) v.pedal_held = true;  // the sustain pedal keeps it ringing until it comes up
        else v.release();
    }
}

void Keys::sustain(bool pedal_down) {
    pedal_ = pedal_down;
    if (pedal_down) return;
    for (auto& v : voices_)
        if (v.active && v.pedal_held) v.release();
}

void Keys::allNotesOff() {
    pedal_ = false;
    for (auto& v : voices_)
        if (v.active && v.live) v.release();
}

void Keys::play(int note, float dur_sec, float velocity, int delay) {
    pickVoice(voices_).start(sr_, note, velocity, delay, std::max(1, int(dur_sec * sr_)));
}

void Keys::stopSequenced() {
    for (auto& v : voices_) stopVoice(v);
}

void Keys::render(float* out, int n) {
    for (auto& v : voices_)
        if (v.active) for (int i = 0; i < n && v.active; ++i) out[i] += v.next();
}

}  // namespace sr
