#pragma once

// Small, allocation-free DSP building blocks used by the instruments, reverb and limiter.

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace sr {

constexpr float kPi = 3.14159265358979f;
constexpr float kTwoPi = 2.0f * kPi;

inline float mtof(float midi) { return 440.0f * std::pow(2.0f, (midi - 69.0f) / 12.0f); }
inline float centsToRatio(float cents) { return std::pow(2.0f, cents / 1200.0f); }

// Multiplier that takes a value from `from` to `to` in `samples` steps (exponential ramp).
inline float expStep(float from, float to, float samples) {
    return std::pow(to / from, 1.0f / std::max(samples, 1.0f));
}

// Per-sample coefficient for a one-pole approach with time constant `tau` seconds.
inline float tauCoef(float tau, float sr) { return std::exp(-1.0f / (tau * sr)); }

// xorshift32: cheap, deterministic white noise. Deterministic so offline test renders are repeatable.
struct Rng {
    uint32_t s = 0x9E3779B9u;
    float next() {  // [-1, 1)
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        return float(s) * (2.0f / 4294967296.0f) - 1.0f;
    }
    float uniform() { return (next() + 1.0f) * 0.5f; }  // [0, 1)
};

// RBJ cookbook biquad in transposed direct form II. Q is linear (not Web Audio's dB).
struct Biquad {
    enum Type { Lowpass, Highpass, Bandpass };
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float z1 = 0, z2 = 0;

    void set(Type type, float sr, float freq, float q) {
        freq = std::clamp(freq, 10.0f, sr * 0.49f);
        const float w = kTwoPi * freq / sr, c = std::cos(w), alpha = std::sin(w) / (2.0f * q);
        const float a0 = 1.0f + alpha;
        float nb0, nb1, nb2;
        switch (type) {
            case Lowpass:  nb0 = (1.0f - c) * 0.5f; nb1 = 1.0f - c;    nb2 = nb0;    break;
            case Highpass: nb0 = (1.0f + c) * 0.5f; nb1 = -(1.0f + c); nb2 = nb0;    break;
            default:       nb0 = alpha;             nb1 = 0.0f;        nb2 = -alpha; break;  // 0 dB peak
        }
        b0 = nb0 / a0; b1 = nb1 / a0; b2 = nb2 / a0;
        a1 = -2.0f * c / a0; a2 = (1.0f - alpha) / a0;
    }
    float process(float x) {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void reset() { z1 = z2 = 0; }
};

// PolyBLEP-corrected sawtooth, so high notes don't alias.
inline float polyBlep(float t, float dt) {
    if (t < dt) { t /= dt; return t + t - t * t - 1.0f; }
    if (t > 1.0f - dt) { t = (t - 1.0f) / dt; return t * t + t + t + 1.0f; }
    return 0.0f;
}

struct SawOsc {
    float phase = 0, inc = 0;
    void setFreq(float freq, float sr) { inc = freq / sr; }
    float next() {
        const float v = 2.0f * phase - 1.0f - polyBlep(phase, inc);
        phase += inc;
        if (phase >= 1.0f) phase -= 1.0f;
        return v;
    }
};

inline float sineOf(float phase) { return std::sin(kTwoPi * phase); }
inline float wrap01(float p) { return p - std::floor(p); }

}  // namespace sr
