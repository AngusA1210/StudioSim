#include "amp.h"

#include <cmath>

namespace sr {
namespace {

float dbToGain(float db) { return std::pow(10.0f, db / 20.0f); }

// A tube-like soft clip: rounder on one side than the other, which adds the even harmonics that make an amp warm.
inline float tube(float x) {
    constexpr float kBias = 0.18f;
    return std::tanh(x + kBias) - std::tanh(kBias);
}

// Shelving and peaking filters (RBJ cookbook), not in dsp.h because only the amps use them.
void lowShelf(Biquad& f, float sr, float hz, float db) {
    const float a = std::pow(10.0f, db / 40.0f), w = kTwoPi * hz / sr, c = std::cos(w), s = std::sin(w);
    const float alpha = s / 2.0f * std::sqrt(2.0f), k = 2.0f * std::sqrt(a) * alpha;
    const float a0 = (a + 1) + (a - 1) * c + k;
    f.b0 = a * ((a + 1) - (a - 1) * c + k) / a0;
    f.b1 = 2 * a * ((a - 1) - (a + 1) * c) / a0;
    f.b2 = a * ((a + 1) - (a - 1) * c - k) / a0;
    f.a1 = -2 * ((a - 1) + (a + 1) * c) / a0;
    f.a2 = ((a + 1) + (a - 1) * c - k) / a0;
}

void highShelf(Biquad& f, float sr, float hz, float db) {
    const float a = std::pow(10.0f, db / 40.0f), w = kTwoPi * hz / sr, c = std::cos(w), s = std::sin(w);
    const float alpha = s / 2.0f * std::sqrt(2.0f), k = 2.0f * std::sqrt(a) * alpha;
    const float a0 = (a + 1) - (a - 1) * c + k;
    f.b0 = a * ((a + 1) + (a - 1) * c + k) / a0;
    f.b1 = -2 * a * ((a - 1) + (a + 1) * c) / a0;
    f.b2 = a * ((a + 1) + (a - 1) * c - k) / a0;
    f.a1 = 2 * ((a - 1) - (a + 1) * c) / a0;
    f.a2 = ((a + 1) - (a - 1) * c - k) / a0;
}

void peak(Biquad& f, float sr, float hz, float q, float db) {
    const float a = std::pow(10.0f, db / 40.0f), w = kTwoPi * hz / sr, alpha = std::sin(w) / (2.0f * q), c = std::cos(w);
    const float a0 = 1 + alpha / a;
    f.b0 = (1 + alpha * a) / a0;
    f.b1 = -2 * c / a0;
    f.b2 = (1 - alpha * a) / a0;
    f.a1 = -2 * c / a0;
    f.a2 = (1 - alpha / a) / a0;
}

}  // namespace

void AmpModel::init(InstrumentKind kind, float sample_rate) {
    kind_ = kind;
    sr_ = sample_rate;
    switch (kind) {
        case InstrumentKind::GuitarStack:
            v_ = {90.0f, 0.75f, 52.0f, 2, 180.0f, 700.0f, 2800.0f, 4500.0f, 0.139f};
            break;
        case InstrumentKind::BassCombo:
            v_ = {30.0f, 0.0f, 24.0f, 1, 70.0f, 450.0f, 2200.0f, 3500.0f, 0.582f};
            break;
        case InstrumentKind::BassStack:
            v_ = {35.0f, 0.2f, 32.0f, 1, 80.0f, 500.0f, 2500.0f, 4000.0f, 0.327f};
            break;
        default:  // the guitar combo
            v_ = {80.0f, 0.4f, 36.0f, 1, 200.0f, 650.0f, 3000.0f, 5000.0f, 0.254f};
            break;
    }
    for (auto* f : {&input_cut_, &tight_cut_, &interstage_, &up_[0], &up_[1], &down_[0], &down_[1], &bass_, &mid_, &treble_, &presence_})
        f->reset();
    input_cut_.set(Biquad::Highpass, sr_, v_.input_cut, 0.707f);
    tight_cut_.set(Biquad::Highpass, sr_ * 2, 650.0f, 0.6f);
    interstage_.set(Biquad::Lowpass, sr_ * 2, 7000.0f, 0.6f);
    for (int i = 0; i < 2; ++i) {  // fourth-order low-passes just under the original Nyquist frequency
        up_[i].set(Biquad::Lowpass, sr_ * 2, sr_ * 0.45f, i == 0 ? 0.54f : 1.31f);
        down_[i].set(Biquad::Lowpass, sr_ * 2, sr_ * 0.45f, i == 0 ? 0.54f : 1.31f);
    }
    // The speaker cabinet: what the cone and the box let through.
    for (auto& f : cabinet_) f.reset();
    switch (kind) {
        case InstrumentKind::GuitarStack:  // closed 4x12: a thump in the lows, a bite at 2-3 kHz, nothing above 5 kHz
            cabinet_[0].set(Biquad::Highpass, sr_, 75.0f, 0.9f);
            peak(cabinet_[1], sr_, 110.0f, 1.2f, 4.0f);
            peak(cabinet_[2], sr_, 2400.0f, 1.0f, 3.0f);
            cabinet_[3].set(Biquad::Lowpass, sr_, 4800.0f, 0.75f);
            cabinet_[4].set(Biquad::Lowpass, sr_, 5200.0f, 0.6f);
            cabinet_stages_ = 5;
            break;
        case InstrumentKind::BassCombo:  // one 15": deep, soft on top
            cabinet_[0].set(Biquad::Highpass, sr_, 38.0f, 0.8f);
            peak(cabinet_[1], sr_, 80.0f, 1.0f, 2.0f);
            cabinet_[2].set(Biquad::Lowpass, sr_, 3200.0f, 0.7f);
            cabinet_[3].set(Biquad::Lowpass, sr_, 3600.0f, 0.6f);
            cabinet_stages_ = 4;
            break;
        case InstrumentKind::BassStack:  // eight 10s: tight lows, a little more top
            cabinet_[0].set(Biquad::Highpass, sr_, 45.0f, 0.8f);
            peak(cabinet_[1], sr_, 100.0f, 1.0f, 3.0f);
            peak(cabinet_[2], sr_, 1500.0f, 1.0f, 2.0f);
            cabinet_[3].set(Biquad::Lowpass, sr_, 5000.0f, 0.7f);
            cabinet_[4].set(Biquad::Lowpass, sr_, 6500.0f, 0.6f);
            cabinet_stages_ = 5;
            break;
        default:  // open-back 1x12: lighter lows, a sweeter top
            cabinet_[0].set(Biquad::Highpass, sr_, 95.0f, 0.7f);
            peak(cabinet_[1], sr_, 150.0f, 1.0f, 2.0f);
            peak(cabinet_[2], sr_, 2500.0f, 1.0f, 3.0f);
            cabinet_[3].set(Biquad::Lowpass, sr_, 5500.0f, 0.75f);
            cabinet_[4].set(Biquad::Lowpass, sr_, 6000.0f, 0.6f);
            cabinet_stages_ = 5;
            break;
    }
    updateFilters();
    master_now_ = master_;
}

void AmpModel::setControl(AmpControl control, float value) {
    knobs_[size_t(control)] = std::clamp(value, 0.0f, 10.0f);
    updateFilters();
}

void AmpModel::updateFilters() {
    const auto knob = [&](AmpControl c) { return knobs_[size_t(c)]; };
    drive_gain_ = dbToGain(knob(AmpControl::Gain) / 10.0f * v_.max_drive_db);
    lowShelf(bass_, sr_, v_.bass_hz, (knob(AmpControl::Bass) - 5.0f) * 2.4f);
    peak(mid_, sr_, v_.mid_hz, 0.7f, (knob(AmpControl::Mid) - 5.0f) * 2.4f);
    highShelf(treble_, sr_, v_.treble_hz, (knob(AmpControl::Treble) - 5.0f) * 2.4f);
    highShelf(presence_, sr_, v_.presence_hz, (knob(AmpControl::Presence) - 5.0f) * 1.2f);
    const float m = knob(AmpControl::Master) / 5.0f;
    master_ = m * m;  // 5 is unity, 10 is +12 dB, 0 is silence
}

float AmpModel::drive(float x) {
    float result = 0.0f;
    for (int phase = 0; phase < 2; ++phase) {  // up to twice the rate: the sample, then a zero, filtered
        float y = up_[1].process(up_[0].process(phase == 0 ? 2.0f * x : 0.0f));
        // Keep some of the lows out of the drive, so it distorts tightly rather than into mud.
        y = (1.0f - v_.tight) * y + v_.tight * tight_cut_.process(y);
        y = tube(y * drive_gain_);
        if (v_.stages > 1) y = tube(interstage_.process(y) * 3.0f);
        y = down_[1].process(down_[0].process(y));
        if (phase == 0) result = y;  // and back down: keep every other sample
    }
    return result;
}

void AmpModel::process(float* io, int n) {
    for (int i = 0; i < n; ++i) {
        float x = input_cut_.process(io[i]);
        x = drive(x);
        x = treble_.process(mid_.process(bass_.process(x)));
        x = presence_.process(x);
        for (int c = 0; c < cabinet_stages_; ++c) x = cabinet_[size_t(c)].process(x);
        master_now_ += (master_ - master_now_) * 0.002f;
        io[i] = x * v_.out_trim * master_now_;
    }
}

Amp::Amp(float sample_rate, InstrumentKind kind, const InputBus* bus, int max_block)
    : Instrument(sample_rate), bus_(bus), in_(size_t(max_block), 0.0f), signal_(size_t(max_block), 0.0f) {
    model_.init(kind, sample_rate);
}

void Amp::render(float* out, int n) {
    n = std::min(n, int(in_.size()));
    std::fill(in_.begin(), in_.begin() + n, 0.0f);
    if (enabled_ && bus_) {  // what is plugged in, as for the Speaker: one input, or all of them together
        const int first = channel_ < 0 ? 0 : channel_, last = channel_ < 0 ? bus_->active : channel_ + 1;
        for (int c = first; c < last && c < bus_->active; ++c) {
            const float* in = bus_->channel[size_t(c)].data();
            for (int i = 0; i < n; ++i) in_[size_t(i)] += in[i];
        }
    }
    std::copy(in_.begin(), in_.begin() + n, signal_.begin());  // the live signal...
    if (looper_) looper_->process(in_.data(), signal_.data(), n, timing_ ? timing_[0] : -1, timing_ ? timing_[1] : 0);  // ...and the loop
    model_.process(signal_.data(), n);
    for (int i = 0; i < n; ++i) out[i] += signal_[size_t(i)];
}

}  // namespace sr
