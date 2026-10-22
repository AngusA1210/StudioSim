#pragma once

// Room reverb and the output limiter (both add zero latency), and the delay that keeps whatever bypasses the
// binaural rendering in step with it.

#include <array>
#include <vector>

#include "dsp.h"

namespace sr {

// A fixed delay that can be brought in and taken out without a click: each sample that arrives is shared between
// passing straight through and coming out `delay` samples late.
class FadedDelay {
public:
    void init(int delay);
    // In place. `from` and `to` are the share that takes the late way, at the start and at the end of these samples:
    // 0 = none of it (the signal passes straight through), 1 = all of it.
    void process(float* x, int n, float from, float to);

private:
    std::vector<float> line_;
    int pos_ = 0;
};

// Eight-line feedback delay network. Each band (below 800 Hz, 800 Hz to 8 kHz, above 8 kHz) dies away in its own
// time, as a room's surfaces and its air have it; left and right are decorrelated, and the output is scaled to unit
// energy so the send level alone sets how wet the room is.
class FdnReverb {
public:
    // `rt60` is the time each band takes to fall 60 dB: low, middle, high. `size` stretches the spacing of the
    // reflections: 1 is a room of ordinary size.
    void init(float sr, const std::array<float, 3>& rt60, float predelay_ms, float size = 1.0f);
    // Mono in, stereo out. Overwrites out_l / out_r.
    void process(const float* in, float* out_l, float* out_r, int n);
    void reset();

private:
    static constexpr int kLines = 8;
    // A first-order shelf (its gain below or above its corner against 1 beyond it), as a line's loss in the low and
    // high bands against the middle's.
    struct Shelf {
        float b0 = 1.0f, b1 = 0.0f, a1 = 0.0f, x1 = 0.0f, y1 = 0.0f;
        float process(float x) {
            const float y = b0 * x + b1 * x1 - a1 * y1;
            x1 = x;
            y1 = y;
            return y;
        }
    };
    std::array<std::vector<float>, kLines> lines_;
    std::array<int, kLines> pos_{}, len_{};
    std::array<float, kLines> gain_{};  // each line's loss in the middle band
    std::array<Shelf, kLines> low_{}, high_{};
    std::vector<float> pre_;
    int pre_pos_ = 0;
    Biquad highpass_;
    float out_gain_ = 1.0f;
};

// Peak limiter without look-ahead (instant attack, 150 ms release), then a soft clip for safety.
class Limiter {
public:
    void init(float sr);
    // Where it holds the peaks: its ceiling, as a gain (-1 dBFS to begin with).
    void setCeiling(float gain) { ceiling_ = std::clamp(gain, 0.01f, 1.0f); }
    // Returns the lowest gain it had to apply in these samples (1 = it did nothing).
    float process(float* l, float* r, int n);
    static constexpr float kDefaultCeilingDb = -1.0f;

private:
    float env_ = 0.0f, release_ = 0.0f;
    float ceiling_ = 0.891f;  // -1 dBFS
};

}  // namespace sr
