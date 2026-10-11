#include "mix.h"

namespace sr {
namespace {

constexpr float kLineMs[8] = {23.3f, 28.9f, 33.7f, 39.1f, 44.9f, 50.3f, 56.1f, 61.7f};
constexpr float kInSign[8] = {1, -1, 1, 1, -1, 1, -1, -1};

inline float softClip(float x) {
    const float a = std::fabs(x);
    if (a <= 0.9f) return x;
    return std::copysign(0.9f + 0.1f * std::tanh((a - 0.9f) / 0.1f), x);
}

}  // namespace

void FdnReverb::init(float sr, float rt60, float predelay_ms, float size) {
    for (int k = 0; k < kLines; ++k) {
        len_[k] = std::max(1, int(kLineMs[k] * size * 0.001f * sr + 0.5f));
        lines_[k].assign(size_t(len_[k]), 0.0f);
        // Loop gain for the target decay, and a one-pole low-pass whose Nyquist gain makes highs decay twice as fast.
        gain_[k] = std::pow(10.0f, -3.0f * float(len_[k]) / (rt60 * sr));
        const float r = gain_[k];
        damp_[k] = (1.0f - r) / (1.0f + r);
    }
    pre_.assign(size_t(std::max(1, int(predelay_ms * 0.001f * sr))), 0.0f);
    highpass_.set(Biquad::Highpass, sr, 160.0f, 0.707f);

    // Measure the impulse response once and normalise it to unit energy.
    out_gain_ = 1.0f;
    reset();
    const int n = int(rt60 * 1.5f * sr);
    std::vector<float> in(static_cast<size_t>(n), 0.0f), l(static_cast<size_t>(n)), r(static_cast<size_t>(n));
    in[0] = 1.0f;
    process(in.data(), l.data(), r.data(), n);
    double energy = 0.0;
    for (float v : l) energy += double(v) * v;
    out_gain_ = energy > 0.0 ? float(1.0 / std::sqrt(energy)) : 1.0f;
    reset();
}

void FdnReverb::reset() {
    for (auto& line : lines_) std::fill(line.begin(), line.end(), 0.0f);
    std::fill(pre_.begin(), pre_.end(), 0.0f);
    pos_.fill(0);
    damp_state_.fill(0.0f);
    pre_pos_ = 0;
    highpass_.reset();
}

void FdnReverb::process(const float* in, float* out_l, float* out_r, int n) {
    const int pre_len = int(pre_.size());
    for (int i = 0; i < n; ++i) {
        float x = pre_[size_t(pre_pos_)];
        pre_[size_t(pre_pos_)] = in[i];
        if (++pre_pos_ == pre_len) pre_pos_ = 0;
        x = highpass_.process(x);

        float y[kLines], sum = 0.0f;
        for (int k = 0; k < kLines; ++k) {
            const float d = lines_[size_t(k)][size_t(pos_[size_t(k)])];
            damp_state_[size_t(k)] = (1.0f - damp_[size_t(k)]) * d + damp_[size_t(k)] * damp_state_[size_t(k)];
            y[k] = damp_state_[size_t(k)] * gain_[size_t(k)];
            sum += y[k];
        }
        sum *= 2.0f / kLines;  // Householder feedback matrix: lossless mixing between lines
        for (int k = 0; k < kLines; ++k) {
            lines_[size_t(k)][size_t(pos_[size_t(k)])] = x * kInSign[k] * 0.35f + (y[k] - sum);
            if (++pos_[size_t(k)] == len_[size_t(k)]) pos_[size_t(k)] = 0;
        }
        out_l[i] = (y[0] - y[2] + y[4] - y[6]) * out_gain_;
        out_r[i] = (y[1] - y[3] + y[5] - y[7]) * out_gain_;
    }
}

void Limiter::init(float sr) {
    release_ = tauCoef(0.15f, sr);
    env_ = 0.0f;
}

float Limiter::process(float* l, float* r, int n) {
    float lowest = 1.0f;
    for (int i = 0; i < n; ++i) {
        const float peak = std::max(std::fabs(l[i]), std::fabs(r[i]));
        env_ = std::max(peak, env_ * release_);
        const float g = env_ > kThreshold ? kThreshold / env_ : 1.0f;
        lowest = std::min(lowest, g);
        l[i] = softClip(l[i] * g);
        r[i] = softClip(r[i] * g);
    }
    return lowest;
}

}  // namespace sr
