#include "mix.h"

namespace sr {
namespace {

constexpr float kLineMs[8] = {23.3f, 28.9f, 33.7f, 39.1f, 44.9f, 50.3f, 56.1f, 61.7f};
constexpr float kInSign[8] = {1, -1, 1, 1, -1, 1, -1, -1};

}  // namespace

void FadedDelay::init(int delay) {
    line_.assign(size_t(std::max(delay, 0)), 0.0f);
    pos_ = 0;
}

void FadedDelay::process(float* x, int n, float from, float to) {
    if (line_.empty()) return;
    for (int i = 0; i < n; ++i) {
        const float share = from + (to - from) * float(i + 1) / float(n);
        const float late = line_[size_t(pos_)];
        line_[size_t(pos_)] = x[i] * share;
        if (++pos_ == int(line_.size())) pos_ = 0;
        x[i] = late + x[i] * (1.0f - share);
    }
}

void FdnReverb::init(float sr, const std::array<float, 3>& rt60, float predelay_ms, float size) {
    // A first-order shelf whose gain is `g` below (low) or above (high) `hz` and 1 beyond, half way (in dB) at `hz`.
    const auto shelf = [&](float hz, float g, bool low) {
        const float k = std::tan(3.14159265f * std::min(hz, 0.45f * sr) / sr), root = std::sqrt(g);
        Shelf s;
        if (low) {
            const float a0 = 1.0f + k / root;
            s.b0 = (1.0f + k * root) / a0;
            s.b1 = (k * root - 1.0f) / a0;
            s.a1 = (k / root - 1.0f) / a0;
        } else {
            const float a0 = 1.0f + k * root;
            s.b0 = (g + k * root) / a0;
            s.b1 = (k * root - g) / a0;
            s.a1 = (k * root - 1.0f) / a0;
        }
        return s;
    };
    for (int k = 0; k < kLines; ++k) {
        len_[k] = std::max(1, int(kLineMs[k] * size * 0.001f * sr + 0.5f));
        lines_[k].assign(size_t(len_[k]), 0.0f);
        // Each band's loss for one trip round this line, for it to fall 60 dB in its own time: the middle's as a gain,
        // the low's and the high's as shelves against it at the bands' edges. (Neither shelf overshoots, so the line
        // never gains.)
        float g[3];
        for (int b = 0; b < 3; ++b) g[b] = std::pow(10.0f, -3.0f * float(len_[k]) / (std::max(rt60[size_t(b)], 0.05f) * sr));
        gain_[k] = g[1];
        low_[k] = shelf(800.0f, g[0] / g[1], true);
        high_[k] = shelf(8000.0f, g[2] / g[1], false);
    }
    const float longest = std::max({rt60[0], rt60[1], rt60[2]});
    pre_.assign(size_t(std::max(1, int(predelay_ms * 0.001f * sr))), 0.0f);
    highpass_.set(Biquad::Highpass, sr, 160.0f, 0.707f);

    // Measure the impulse response once and normalise it to unit energy.
    out_gain_ = 1.0f;
    reset();
    const int n = int(longest * 1.5f * sr);
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
    for (auto* shelves : {&low_, &high_})
        for (Shelf& s : *shelves) s.x1 = s.y1 = 0.0f;
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
            y[k] = high_[size_t(k)].process(low_[size_t(k)].process(d)) * gain_[size_t(k)];
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

void Smear::init(float sr) {
    constexpr float kStageMs[kStages] = {1.7f, 3.1f, 5.3f, 8.9f};
    for (int k = 0; k < kStages; ++k) lines_[size_t(k)].assign(size_t(std::max(1, int(kStageMs[k] * 0.001f * sr + 0.5f))), 0.0f);
    pos_.fill(0);
}

void Smear::reset() {
    for (auto& line : lines_) std::fill(line.begin(), line.end(), 0.0f);
    pos_.fill(0);
}

void Smear::process(float* io, int n) {
    constexpr float g = 0.6f;
    for (int k = 0; k < kStages; ++k) {
        std::vector<float>& line = lines_[size_t(k)];
        if (line.empty()) continue;
        int pos = pos_[size_t(k)];
        const int len = int(line.size());
        for (int i = 0; i < n; ++i) {  // (Schroeder's all-pass: what went in `len` ago, less this, plus this fed back)
            const float held = line[size_t(pos)];
            const float v = io[i] + g * held;
            io[i] = held - g * v;
            line[size_t(pos)] = v;
            if (++pos == len) pos = 0;
        }
        pos_[size_t(k)] = pos;
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
        env_ = std::max(peak, env_ * release_);  // (it reacts at once, so nothing gets past the ceiling)
        const float g = env_ > ceiling_ ? ceiling_ / env_ : 1.0f;
        lowest = std::min(lowest, g);
        l[i] *= g;
        r[i] *= g;
    }
    return lowest;
}

}  // namespace sr
