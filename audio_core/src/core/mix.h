#pragma once

// Room reverb and the output limiter. Both add zero latency.

#include <array>
#include <vector>

#include "dsp.h"

namespace sr {

// Eight-line feedback delay network. Highs decay faster than lows, left and right are decorrelated,
// and the output is scaled to unit energy so the send level alone sets how wet the room is.
class FdnReverb {
public:
    // `size` stretches the spacing of the reflections: 1 is a room of ordinary size.
    void init(float sr, float rt60, float predelay_ms, float size = 1.0f);
    // Mono in, stereo out. Overwrites out_l / out_r.
    void process(const float* in, float* out_l, float* out_r, int n);
    void reset();

private:
    static constexpr int kLines = 8;
    std::array<std::vector<float>, kLines> lines_;
    std::array<int, kLines> pos_{}, len_{};
    std::array<float, kLines> gain_{}, damp_{}, damp_state_{};
    std::vector<float> pre_;
    int pre_pos_ = 0;
    Biquad highpass_;
    float out_gain_ = 1.0f;
};

// Peak limiter without look-ahead (instant attack, 150 ms release), then a soft clip for safety.
class Limiter {
public:
    void init(float sr);
    void process(float* l, float* r, int n);

private:
    float env_ = 0.0f, release_ = 0.0f;
    static constexpr float kThreshold = 0.8f;
};

}  // namespace sr
