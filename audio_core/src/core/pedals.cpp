#include "pedals.h"

#include <cmath>
#include <vector>

#include "plugin_host.h"

namespace sr {
namespace {

constexpr int kChunk = 64;            // switching a pedal crossfades through a buffer this long at a time
constexpr float kSwitchSeconds = 0.01f;

float dbToGain(float db) { return std::pow(10.0f, db / 20.0f); }
float clampKnob(float knob) { return std::clamp(knob, 0.0f, 10.0f); }
// A knob spread evenly in ratio between two values, as for times and frequencies.
float logKnob(float knob, float low, float high) { return low * std::pow(high / low, clampKnob(knob) / 10.0f); }
float linKnob(float knob, float low, float high) { return low + (high - low) * clampKnob(knob) / 10.0f; }
// An output level: 5 is unity, 10 is +12 dB, 0 is silence (as on the amps' Master).
float levelKnob(float knob) {
    const float m = clampKnob(knob) / 5.0f;
    return m * m;
}

struct OnePole {
    float a = 0.0f, z = 0.0f;
    void set(float sr, float hz) { a = std::exp(-kTwoPi * std::min(hz, sr * 0.45f) / sr); }
    float lowpass(float x) { return z = x + a * (z - x); }
    float highpass(float x) { return x - lowpass(x); }
};

// Runs a waveshaper at twice the sample rate, so the harmonics it adds don't fold back down as harsh tones.
struct Oversampler {
    Biquad up[2], down[2];
    void init(float sr) {
        for (int i = 0; i < 2; ++i) {  // fourth-order low-passes just under the original Nyquist frequency
            up[i].set(Biquad::Lowpass, sr * 2, sr * 0.45f, i == 0 ? 0.54f : 1.31f);
            down[i] = up[i];
            up[i].reset();
            down[i].reset();
        }
    }
    template <class Shape>
    float process(float x, Shape&& shape) {
        float result = 0.0f;
        for (int phase = 0; phase < 2; ++phase) {
            float y = up[1].process(up[0].process(phase == 0 ? 2.0f * x : 0.0f));
            y = down[1].process(down[0].process(shape(y)));
            if (phase == 0) result = y;
        }
        return result;
    }
};

// A delay line read between samples (cubic interpolation), for chorus, phaser and echo.
struct DelayLine {
    std::vector<float> buf;
    int w = 0;
    void init(int size) {
        buf.assign(size_t(std::max(size, 8)), 0.0f);
        w = 0;
    }
    void clear() { std::fill(buf.begin(), buf.end(), 0.0f); }
    void push(float x) {
        buf[size_t(w)] = x;
        if (++w == int(buf.size())) w = 0;
    }
    float read(float delay) const {  // `delay` samples after it was pushed (2 or more)
        const int size = int(buf.size());
        delay = std::clamp(delay, 2.0f, float(size - 4));
        float pos = float(w) - delay;
        if (pos < 0.0f) pos += float(size);
        const int i = int(pos);
        const float f = pos - float(i);
        auto at = [&](int k) { return buf[size_t(k < 0 ? k + size : (k >= size ? k - size : k))]; };
        const float y0 = at(i - 1), y1 = at(i), y2 = at(i + 1), y3 = at(i + 2);
        const float c1 = 0.5f * (y2 - y0), c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
        const float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
        return ((c3 * f + c2) * f + c1) * f + y1;
    }
};

// ── Dynamics ───────────────────────────────────────────────────────────────────────────────────────────────

class Gate final : public Pedal {
public:
    Gate() : Pedal(PedalKind::Gate) {}

protected:
    void update() override {
        open_at_ = dbToGain(linKnob(control(0), -80.0f, -20.0f));
        close_at_ = open_at_ * 0.5f;  // it shuts 6 dB lower than it opens, so it doesn't chatter on a fading note
        release_ = std::exp(-1.0f / (logKnob(control(1), 0.01f, 1.0f) * sr_ / 6.9f));  // to -60 dB in that time
        attack_ = std::exp(-1.0f / (0.0005f * sr_));
        follow_ = std::exp(-1.0f / (0.03f * sr_));
        hold_for_ = int(0.03f * sr_);
    }
    void clear() override { env_ = gain_ = 0.0f; }
    void run(float* io, int n, const PedalTiming&) override {
        for (int i = 0; i < n; ++i) {
            env_ = std::max(std::fabs(io[i]), env_ * follow_);
            if (env_ > open_at_) {
                open_ = true;
                hold_ = hold_for_;
            } else if (env_ < close_at_) {
                if (hold_ > 0) --hold_;
                else open_ = false;
            }
            gain_ = open_ ? 1.0f + (gain_ - 1.0f) * attack_ : gain_ * release_;
            io[i] *= gain_;
        }
    }

private:
    float open_at_ = 0, close_at_ = 0, release_ = 0, attack_ = 0, follow_ = 0, env_ = 0, gain_ = 0;
    int hold_for_ = 0, hold_ = 0;
    bool open_ = false;
};

class Compressor final : public Pedal {
public:
    Compressor() : Pedal(PedalKind::Compressor) {}

protected:
    void update() override {
        threshold_ = -8.0f - 3.2f * clampKnob(control(0));  // Sustain: from gentle to squashed
        ratio_ = 2.0f + 0.8f * clampKnob(control(0));
        attack_ = std::exp(-1.0f / (logKnob(control(1), 0.0005f, 0.05f) * sr_));
        release_ = std::exp(-1.0f / (0.15f * sr_));
        makeup_ = -threshold_ * (1.0f - 1.0f / ratio_) * 0.5f;  // brings it back up to about where it was
        level_ = levelKnob(control(2));
        blend_ = clampKnob(control(3)) / 10.0f;  // 10: all compressed; less mixes the untouched signal back in
    }
    void clear() override { env_ = 0.0f; }
    void run(float* io, int n, const PedalTiming&) override {
        constexpr float kKnee = 6.0f;
        const float slope = 1.0f - 1.0f / ratio_;
        for (int i = 0; i < n; ++i) {
            const float x = io[i], a = std::fabs(x);
            env_ = a > env_ ? a + (env_ - a) * attack_ : a + (env_ - a) * release_;
            const float over = 20.0f * std::log10(env_ + 1e-9f) - threshold_;
            float reduce = 0.0f;
            if (over >= kKnee / 2) reduce = over * slope;
            else if (over > -kKnee / 2) reduce = slope * (over + kKnee / 2) * (over + kKnee / 2) / (2.0f * kKnee);
            const float squashed = x * dbToGain(makeup_ - reduce);
            io[i] = (blend_ * squashed + (1.0f - blend_) * x) * level_;
        }
    }

private:
    float threshold_ = 0, ratio_ = 1, attack_ = 0, release_ = 0, makeup_ = 0, level_ = 1, blend_ = 1, env_ = 0;
};

// ── Drive ──────────────────────────────────────────────────────────────────────────────────────────────────

// After the classic green overdrive: only the mids and highs are driven into the clipping diodes and the clean
// signal is mixed back in, so the lows stay tight and the amp behind it is pushed rather than buried.
class Overdrive final : public Pedal {
public:
    Overdrive() : Pedal(PedalKind::Overdrive) {}
    void prepare(float sample_rate) override {
        Pedal::prepare(sample_rate);
        os_.init(sr_);
        hump_.set(sr_, 720.0f);
        hump_.z = 0.0f;
        fizz_.set(sr_, 9000.0f);
    }

protected:
    void update() override {
        gain_ = dbToGain(linKnob(control(0), 6.0f, 42.0f));
        tone_.set(sr_, logKnob(control(1), 700.0f, 7000.0f));
        level_ = levelKnob(control(2)) * kTrim;
    }
    void clear() override { hump_.z = tone_.z = fizz_.z = 0.0f; }
    void run(float* io, int n, const PedalTiming&) override {
        for (int i = 0; i < n; ++i) {
            const float x = io[i];
            const float driven = os_.process(hump_.highpass(x) * gain_, [](float v) { return std::tanh(v); });
            io[i] = fizz_.lowpass(tone_.lowpass(x + 0.6f * driven)) * level_;
        }
    }

private:
    static constexpr float kTrim = 0.35f;  // a plucked string comes out at about the level it went in, Level at 5
    Oversampler os_;
    OnePole hump_, tone_, fizz_;
    float gain_ = 1, level_ = 1;
};

// After the big three-knob fuzz: two clipping stages one after the other, then a tone control that sweeps from
// dark to bright through a scooped middle.
class Fuzz final : public Pedal {
public:
    Fuzz() : Pedal(PedalKind::Fuzz) {}
    void prepare(float sample_rate) override {
        Pedal::prepare(sample_rate);
        os_.init(sr_);
        input_.set(sr_, 90.0f);
        between_.set(Biquad::Lowpass, sr_ * 2, 4500.0f, 0.7f);
        dark_.set(sr_, 450.0f);
        bright_.set(sr_, 1100.0f);
        clear();
    }

protected:
    void update() override {
        gain_ = dbToGain(linKnob(control(0), 14.0f, 50.0f));
        tilt_ = clampKnob(control(1)) / 10.0f;
        level_ = levelKnob(control(2)) * kTrim;
    }
    void clear() override {
        input_.z = dark_.z = bright_.z = 0.0f;
        between_.reset();
    }
    void run(float* io, int n, const PedalTiming&) override {
        for (int i = 0; i < n; ++i) {
            const float y = os_.process(input_.highpass(io[i]) * gain_, [this](float v) {
                v = v > 0.0f ? std::tanh(v) : 0.8f * std::tanh(v / 0.8f);  // the two halves clip a little differently
                return std::tanh(between_.process(v) * 6.0f);
            });
            io[i] = ((1.0f - tilt_) * dark_.lowpass(y) + tilt_ * 1.4f * bright_.highpass(y)) * level_;
        }
    }

private:
    static constexpr float kTrim = 0.22f;
    Oversampler os_;
    OnePole input_, dark_, bright_;
    Biquad between_;
    float gain_ = 1, tilt_ = 0.5f, level_ = 1;
};

// ── Filter and modulation ──────────────────────────────────────────────────────────────────────────────────

// A resonant filter whose frequency follows how hard the strings are struck: the auto-wah.
class EnvelopeFilter final : public Pedal {
public:
    EnvelopeFilter() : Pedal(PedalKind::EnvelopeFilter) {}

protected:
    void update() override {
        sensitivity_ = dbToGain(linKnob(control(0), -6.0f, 30.0f));
        top_ = logKnob(control(1), 600.0f, 5000.0f);
        k_ = 1.0f / logKnob(control(2), 0.7f, 10.0f);
        band_ = control(3) > 0.5f;
        attack_ = std::exp(-1.0f / (0.002f * sr_));
        release_ = std::exp(-1.0f / (0.08f * sr_));
        countdown_ = 0;
    }
    void clear() override { env_ = ic1_ = ic2_ = 0.0f; }
    void run(float* io, int n, const PedalTiming&) override {
        constexpr float kBottom = 150.0f;
        for (int i = 0; i < n; ++i) {
            const float a = std::fabs(io[i]);
            env_ = a > env_ ? a + (env_ - a) * attack_ : a + (env_ - a) * release_;
            if (countdown_-- <= 0) {  // the filter's coefficients, every few samples
                countdown_ = 8;
                const float amount = std::min(env_ * sensitivity_, 1.0f);
                const float hz = kBottom * std::pow(top_ / kBottom, amount);
                const float g = std::tan(kPi * std::min(hz, sr_ * 0.45f) / sr_);
                a1_ = 1.0f / (1.0f + g * (g + k_));
                a2_ = g * a1_;
                a3_ = g * a2_;
            }
            // A state-variable filter (topology-preserving: it stays stable while it sweeps).
            const float v3 = io[i] - ic2_;
            const float v1 = a1_ * ic1_ + a2_ * v3;
            const float v2 = ic2_ + a2_ * ic1_ + a3_ * v3;
            ic1_ = 2.0f * v1 - ic1_;
            ic2_ = 2.0f * v2 - ic2_;
            io[i] = band_ ? 2.0f * k_ * v1 : v2;
        }
    }

private:
    float sensitivity_ = 1, top_ = 1000, k_ = 1, attack_ = 0, release_ = 0, env_ = 0;
    float ic1_ = 0, ic2_ = 0, a1_ = 1, a2_ = 0, a3_ = 0;
    int countdown_ = 0;
    bool band_ = true;
};

class Chorus final : public Pedal {
public:
    Chorus() : Pedal(PedalKind::Chorus) {}
    void prepare(float sample_rate) override {
        Pedal::prepare(sample_rate);
        line_.init(int(0.03f * sr_));
    }

protected:
    void update() override {
        rate_ = logKnob(control(0), 0.1f, 6.0f) / sr_;
        depth_ = linKnob(control(1), 0.0f, 4.0f) * 0.001f * sr_;
        mix_ = clampKnob(control(2)) / 10.0f;  // 5: half and half, the classic chorus; 10: only the wavering copy (vibrato)
    }
    void clear() override { line_.clear(); }
    void run(float* io, int n, const PedalTiming&) override {
        const float base = 0.007f * sr_;
        for (int i = 0; i < n; ++i) {
            phase_ = wrap01(phase_ + rate_);
            line_.push(io[i]);
            const float wet = line_.read(base + depth_ * (0.5f + 0.5f * sineOf(phase_)));
            io[i] = io[i] * (1.0f - mix_) + wet * mix_;
        }
    }

private:
    DelayLine line_;
    float rate_ = 0, depth_ = 0, mix_ = 0.5f, phase_ = 0;
};

class Phaser final : public Pedal {
public:
    Phaser() : Pedal(PedalKind::Phaser) {}

protected:
    void update() override {
        rate_ = logKnob(control(0), 0.05f, 6.0f) / sr_;
        top_ = 200.0f * (1.0f + 15.0f * clampKnob(control(1)) / 10.0f);
        feedback_ = linKnob(control(2), 0.0f, 0.8f);
    }
    void clear() override {
        for (float& s : state_) s = 0.0f;
        last_ = 0.0f;
    }
    void run(float* io, int n, const PedalTiming&) override {
        constexpr float kBottom = 200.0f;
        for (int i = 0; i < n; ++i) {
            phase_ = wrap01(phase_ + rate_);
            if (countdown_-- <= 0) {
                countdown_ = 8;
                const float sweep = 0.5f - 0.5f * std::cos(kTwoPi * phase_);
                const float t = std::tan(kPi * std::min(kBottom * std::pow(top_ / kBottom, sweep), sr_ * 0.45f) / sr_);
                coef_ = (t - 1.0f) / (t + 1.0f);
            }
            float y = io[i] + feedback_ * last_;
            for (float& s : state_) {  // four first-order all-passes
                const float out = coef_ * y + s;
                s = y - coef_ * out;
                y = out;
            }
            last_ = y;
            io[i] = 0.5f * (io[i] + y);
        }
    }

private:
    float rate_ = 0, top_ = 1000, feedback_ = 0, phase_ = 0, coef_ = 0, last_ = 0;
    float state_[4] = {};
    int countdown_ = 0;
};

class Tremolo final : public Pedal {
public:
    Tremolo() : Pedal(PedalKind::Tremolo) {}

protected:
    void update() override {
        rate_ = logKnob(control(0), 1.0f, 12.0f) / sr_;
        depth_ = clampKnob(control(1)) / 10.0f;
        shape_ = linKnob(control(2), 1.0f, 20.0f);  // from a smooth sine towards a square wave's hard chop
        norm_ = 1.0f / std::tanh(shape_);
    }
    void run(float* io, int n, const PedalTiming&) override {
        for (int i = 0; i < n; ++i) {
            phase_ = wrap01(phase_ + rate_);
            const float wave = std::tanh(shape_ * sineOf(phase_)) * norm_;
            io[i] *= 1.0f - depth_ * (0.5f - 0.5f * wave);
        }
    }

private:
    float rate_ = 0, depth_ = 0, shape_ = 1, norm_ = 1, phase_ = 0;
};

// ── Time ───────────────────────────────────────────────────────────────────────────────────────────────────

// Echoes that grow darker with each repeat, as a tape or bucket-brigade delay's do. Turning Time glides the echo to
// its new place (and bends its pitch on the way, as theirs do). With Sync on, Time picks a note value at the room's
// tempo instead: a sixteenth, an eighth-note triplet, an eighth, a dotted eighth, a quarter-note triplet, a quarter,
// a dotted quarter, a half.
class Delay final : public Pedal {
public:
    static constexpr float kMaxSeconds = 3.0f;
    static constexpr float kBeats[8] = {0.25f, 1.0f / 3.0f, 0.5f, 0.75f, 2.0f / 3.0f, 1.0f, 1.5f, 2.0f};

    Delay() : Pedal(PedalKind::Delay) {}
    void prepare(float sample_rate) override {
        Pedal::prepare(sample_rate);
        line_.init(int(kMaxSeconds * sr_) + 8);
        delay_ = -1.0f;
        tone_.z = 0.0f;
    }

protected:
    bool trails() const override { return true; }
    void update() override {
        seconds_ = logKnob(control(0), 0.04f, 1.5f);
        division_ = int(std::lround(clampKnob(control(0)) / 10.0f * 7.0f));
        repeats_ = 0.95f * clampKnob(control(1)) / 10.0f;
        mix_ = clampKnob(control(2)) / 10.0f;
        tone_.set(sr_, logKnob(control(3), 1200.0f, 12000.0f));
        sync_ = control(4) > 0.5f;
        glide_ = 1.0f - std::exp(-1.0f / (0.08f * sr_));
    }
    void runTrails(float* io, int n, float feed_from, float feed_to, const PedalTiming& timing) override {
        const double beat = timing.beat_samples;
        float target = sync_ && beat > 0.0 ? float(beat) * kBeats[size_t(division_)] : seconds_ * sr_;
        target = std::clamp(target, 2.0f, kMaxSeconds * sr_);
        if (delay_ < 0.0f) delay_ = target;
        for (int i = 0; i < n; ++i) {
            delay_ += (target - delay_) * glide_;
            const float echo = tone_.lowpass(line_.read(delay_));
            const float feed = feed_from + (feed_to - feed_from) * float(i + 1) / float(n);
            line_.push(io[i] * feed + echo * repeats_);
            io[i] += echo * mix_;
        }
    }
    void run(float*, int, const PedalTiming&) override {}

private:
    DelayLine line_;
    OnePole tone_;
    float seconds_ = 0.3f, repeats_ = 0, mix_ = 0, glide_ = 0, delay_ = -1.0f;
    int division_ = 5;
    bool sync_ = false;
};

// Eight delay lines feeding back into one another through a lossless mix, each darkened a little on every pass: the
// same kind of reverb as the room's, but with a decay you set.
class Reverb final : public Pedal {
public:
    Reverb() : Pedal(PedalKind::Reverb) {}
    void prepare(float sample_rate) override {
        Pedal::prepare(sample_rate);
        static constexpr float kLineMs[kLines] = {29.7f, 37.1f, 41.1f, 43.7f, 53.0f, 59.9f, 67.7f, 73.1f};
        for (int k = 0; k < kLines; ++k) {
            len_[k] = std::max(1, int(kLineMs[k] * 0.001f * sr_));
            lines_[k].assign(size_t(len_[k]), 0.0f);
            pos_[k] = 0;
            damp_[k].z = 0.0f;
        }
        for (int a = 0; a < 2; ++a) {
            diffuse_[a].assign(size_t(std::max(1, int((a == 0 ? 4.7f : 1.6f) * 0.001f * sr_))), 0.0f);
            diffuse_pos_[a] = 0;
        }
    }

protected:
    bool trails() const override { return true; }
    void update() override {
        const float rt60 = logKnob(control(0), 0.3f, 8.0f);
        for (int k = 0; k < kLines; ++k) {
            gain_[k] = std::pow(10.0f, -3.0f * float(len_[k]) / (rt60 * sr_));
            damp_[k].set(sr_, logKnob(control(1), 1500.0f, 12000.0f));
        }
        wet_ = clampKnob(control(2)) / 10.0f * 0.5f / std::sqrt(rt60);  // a longer tail holds more energy
    }
    void runTrails(float* io, int n, float feed_from, float feed_to, const PedalTiming&) override {
        constexpr float kInSign[kLines] = {1, -1, 1, 1, -1, 1, -1, -1};
        for (int i = 0; i < n; ++i) {
            float x = io[i] * (feed_from + (feed_to - feed_from) * float(i + 1) / float(n));
            for (int a = 0; a < 2; ++a) {  // two all-passes smear the attack before it enters the lines
                auto& line = diffuse_[a];
                const float held = line[size_t(diffuse_pos_[a])];
                const float out = held - 0.6f * x;
                line[size_t(diffuse_pos_[a])] = x + 0.6f * out;
                if (++diffuse_pos_[a] == int(line.size())) diffuse_pos_[a] = 0;
                x = out;
            }
            float y[kLines], sum = 0.0f;
            for (int k = 0; k < kLines; ++k) {
                y[k] = damp_[k].lowpass(lines_[k][size_t(pos_[k])]) * gain_[k];
                sum += y[k];
            }
            sum *= 2.0f / kLines;  // Householder feedback: lossless mixing between the lines
            float out = 0.0f;
            for (int k = 0; k < kLines; ++k) {
                lines_[k][size_t(pos_[k])] = x * kInSign[k] * 0.35f + (y[k] - sum);
                if (++pos_[k] == len_[k]) pos_[k] = 0;
                out += (k % 2 ? -y[k] : y[k]);
            }
            io[i] += out * wet_;
        }
    }
    void run(float*, int, const PedalTiming&) override {}

private:
    static constexpr int kLines = 8;
    std::array<std::vector<float>, kLines> lines_;
    std::array<int, kLines> len_{}, pos_{};
    std::array<float, kLines> gain_{};
    std::array<OnePole, kLines> damp_;
    std::array<std::vector<float>, 2> diffuse_;
    std::array<int, 2> diffuse_pos_{};
    float wet_ = 0.0f;
};

}  // namespace

// ── The pedal ──────────────────────────────────────────────────────────────────────────────────────────────

PedalControls defaultPedalControls(PedalKind kind) {
    switch (kind) {
        case PedalKind::Tuner:          return {1, 0, 0, 0, 0};       // Mute
        case PedalKind::Gate:           return {3.5f, 4, 0, 0, 0};    // Threshold (-59 dB), Release (60 ms)
        case PedalKind::Compressor:     return {5, 3, 5, 10, 0};      // Sustain, Attack, Level, Blend
        case PedalKind::Overdrive:      return {5, 5, 5, 0, 0};       // Drive, Tone, Level
        case PedalKind::Fuzz:           return {6, 5, 5, 0, 0};       // Sustain, Tone, Volume
        case PedalKind::EnvelopeFilter: return {5, 5, 5, 1, 0};       // Sensitivity, Range, Resonance, Band-pass
        case PedalKind::Chorus:         return {4, 5, 5, 0, 0};       // Rate, Depth, Mix
        case PedalKind::Phaser:         return {3, 7, 4, 0, 0};       // Rate, Depth, Resonance
        case PedalKind::Tremolo:        return {5, 6, 3, 0, 0};       // Rate, Depth, Shape
        case PedalKind::Delay:          return {5.5f, 4, 4, 5, 0};    // Time (290 ms), Repeats, Mix, Tone, Sync
        case PedalKind::Reverb:         return {5, 5, 3, 0, 0};       // Decay (1.5 s), Tone, Mix
        case PedalKind::Looper:         return {5, 1, 0, 0, 0};       // Level, Sync, Overdub after recording
        default:                        return {0, 0, 0, 0, 0};
    }
}

int pedalControlCount(PedalKind kind) {
    switch (kind) {
        case PedalKind::Tuner: return 1;
        case PedalKind::Gate: return 2;
        case PedalKind::Compressor: case PedalKind::EnvelopeFilter: return 4;
        case PedalKind::Delay: return 5;
        case PedalKind::Plugin: return 0;
        default: return 3;
    }
}

std::unique_ptr<Pedal> Pedal::make(PedalKind kind, float sample_rate) {
    std::unique_ptr<Pedal> pedal;
    switch (kind) {
        case PedalKind::Tuner:          pedal = std::make_unique<TunerPedal>(); break;
        case PedalKind::Gate:           pedal = std::make_unique<Gate>(); break;
        case PedalKind::Compressor:     pedal = std::make_unique<Compressor>(); break;
        case PedalKind::Overdrive:      pedal = std::make_unique<Overdrive>(); break;
        case PedalKind::Fuzz:           pedal = std::make_unique<Fuzz>(); break;
        case PedalKind::EnvelopeFilter: pedal = std::make_unique<EnvelopeFilter>(); break;
        case PedalKind::Chorus:         pedal = std::make_unique<Chorus>(); break;
        case PedalKind::Phaser:         pedal = std::make_unique<Phaser>(); break;
        case PedalKind::Tremolo:        pedal = std::make_unique<Tremolo>(); break;
        case PedalKind::Delay:          pedal = std::make_unique<Delay>(); break;
        case PedalKind::Reverb:         pedal = std::make_unique<Reverb>(); break;
        case PedalKind::Looper:         pedal = std::make_unique<LooperPedal>(); break;
        case PedalKind::Plugin:         pedal = std::make_unique<PluginPedal>(); break;
        default: return nullptr;
    }
    pedal->prepare(sample_rate);
    return pedal;
}

Pedal::Pedal(PedalKind kind) : kind_(kind), controls_(defaultPedalControls(kind)) {}

void Pedal::prepare(float sample_rate) {
    sr_ = sample_rate;
    changed_ = true;
}

void Pedal::setControl(int index, float value) {
    if (index < 0 || index >= kPedalControls) return;
    controls_[size_t(index)] = value;
    changed_ = true;
}

void Pedal::process(float* io, int n, const PedalTiming& timing) {
    started_ = true;
    if (changed_) {
        update();
        changed_ = false;
    }
    const float target = on_ ? 1.0f : 0.0f, step = 1.0f / (kSwitchSeconds * sr_);
    if (trails()) {
        const float from = share_;
        share_ = target > share_ ? std::min(share_ + step * float(n), 1.0f) : std::max(share_ - step * float(n), 0.0f);
        runTrails(io, n, from, share_, timing);
        return;
    }
    if (share_ == 0.0f && target == 0.0f) return;  // bypassed: the signal passes untouched
    if (share_ == 0.0f) clear();
    if (share_ == 1.0f && target == 1.0f) {
        run(io, n, timing);
        return;
    }
    float dry[kChunk];  // switching: crossfade between the untouched signal and the effect
    for (int done = 0; done < n;) {
        const int m = std::min(n - done, kChunk);
        std::copy(io + done, io + done + m, dry);
        PedalTiming part = timing;  // the next bar line, counted from this part of the block
        if (part.next_bar >= 0) part.next_bar = std::max<int64_t>(part.next_bar - done, 0);
        run(io + done, m, part);
        for (int i = 0; i < m; ++i) {
            share_ = target > share_ ? std::min(share_ + step, 1.0f) : std::max(share_ - step, 0.0f);
            io[done + i] = dry[i] + (io[done + i] - dry[i]) * share_;
        }
        done += m;
    }
}

void Pedal::processStereo(float* left, float* right, int n, const PedalTiming& timing) {
    started_ = true;
    if (changed_) {
        update();
        changed_ = false;
    }
    const float target = on_ ? 1.0f : 0.0f, step = 1.0f / (kSwitchSeconds * sr_);
    if (share_ == 0.0f && target == 0.0f) return;  // bypassed: the signal passes untouched
    if (share_ == 0.0f) clear();
    if (share_ == 1.0f && target == 1.0f) {
        runStereo(left, right, n, timing);
        return;
    }
    float dry_l[kChunk], dry_r[kChunk];  // switching: crossfade between the untouched signal and the effect
    for (int done = 0; done < n;) {
        const int m = std::min(n - done, kChunk);
        std::copy(left + done, left + done + m, dry_l);
        std::copy(right + done, right + done + m, dry_r);
        PedalTiming part = timing;
        if (part.next_bar >= 0) part.next_bar = std::max<int64_t>(part.next_bar - done, 0);
        runStereo(left + done, right + done, m, part);
        for (int i = 0; i < m; ++i) {
            share_ = target > share_ ? std::min(share_ + step, 1.0f) : std::max(share_ - step, 0.0f);
            left[done + i] = dry_l[i] + (left[done + i] - dry_l[i]) * share_;
            right[done + i] = dry_r[i] + (right[done + i] - dry_r[i]) * share_;
        }
        done += m;
    }
}

// ── The tuner ──────────────────────────────────────────────────────────────────────────────────────────────

TunerPedal::TunerPedal() : Pedal(PedalKind::Tuner) {}

void TunerPedal::prepare(float sample_rate) {
    Pedal::prepare(sample_rate);
    factor_ = std::max(1, int(std::lround(sample_rate / 12000.0f)));
    rate_ = sample_rate / float(factor_);
    for (int i = 0; i < 2; ++i) {
        smooth_[i].set(Biquad::Lowpass, sample_rate, std::min(2500.0f, rate_ * 0.4f), i == 0 ? 0.54f : 1.31f);
        smooth_[i].reset();
    }
    if (!ring_) ring_.reset(new std::atomic<float>[kRing]);
    clear();
}

void TunerPedal::clear() {
    for (int i = 0; i < kRing; ++i) ring_[size_t(i)].store(0.0f, std::memory_order_relaxed);
    phase_ = 0;
}

void TunerPedal::run(float* io, int n, const PedalTiming&) {
    uint32_t w = written_.load(std::memory_order_relaxed);
    const bool mute = control(0) > 0.5f;
    for (int i = 0; i < n; ++i) {
        const float s = smooth_[1].process(smooth_[0].process(io[i]));
        if (++phase_ >= factor_) {
            phase_ = 0;
            ring_[w % kRing].store(s, std::memory_order_relaxed);
            ++w;
        }
        if (mute) io[i] = 0.0f;  // tune in silence, as on stage
    }
    written_.store(w, std::memory_order_release);
}

TunerReading TunerPedal::read() const {
    const int count = std::min(kRing, int(rate_ * 0.125f));  // the last eighth of a second
    std::vector<float> x(static_cast<size_t>(count));
    const uint32_t end = written_.load(std::memory_order_acquire);
    for (int i = 0; i < count; ++i) x[size_t(i)] = ring_[(end - uint32_t(count) + uint32_t(i)) % kRing].load(std::memory_order_relaxed);
    TunerReading r = detectPitch(x.data(), count, rate_);
    r.listening = true;
    return r;
}

TunerReading detectPitch(const float* x, int n, float rate) {
    TunerReading r;
    const int max_lag = std::min(int(rate / 25.0f), n / 2), min_lag = std::max(2, int(rate / 1400.0f));
    const int window = n - max_lag;
    if (window < 32 || max_lag <= min_lag + 2) return r;
    double energy = 0.0;
    for (int i = 0; i < n; ++i) energy += double(x[i]) * x[i];
    if (std::sqrt(energy / n) < 0.001) return r;  // quieter than -60 dBFS: nothing to tune to

    // How unlike itself the signal is when shifted by each lag, normalised by the average up to that lag: dips
    // towards zero at the period and its multiples.
    std::vector<float> d(static_cast<size_t>(max_lag + 1), 1.0f), raw(static_cast<size_t>(max_lag + 1), 0.0f);
    double running = 0.0;
    for (int lag = 1; lag <= max_lag; ++lag) {
        double sum = 0.0;
        for (int j = 0; j < window; ++j) {
            const double diff = double(x[j]) - x[j + lag];
            sum += diff * diff;
        }
        running += sum;
        raw[size_t(lag)] = float(sum);
        d[size_t(lag)] = running > 0.0 ? float(sum * lag / running) : 1.0f;
    }
    int lag = -1;
    for (int t = min_lag; t <= max_lag; ++t) {
        if (d[size_t(t)] < 0.15f) {  // the first clear dip is the period, rather than a deeper one at twice it
            while (t + 1 <= max_lag && d[size_t(t + 1)] < d[size_t(t)]) ++t;
            lag = t;
            break;
        }
    }
    if (lag < 0) return r;
    float exact = float(lag);
    if (lag > 1 && lag < max_lag) {  // between samples, from the shape of the dip in the plain differences
        const float a = raw[size_t(lag - 1)], b = raw[size_t(lag)], c = raw[size_t(lag + 1)];
        const float curve = a - 2.0f * b + c;
        if (curve > 0.0f) exact += 0.5f * (a - c) / curve;
    }
    r.pitched = true;
    r.frequency = rate / exact;
    const double midi = 69.0 + 12.0 * std::log2(r.frequency / 440.0);
    r.note = int(std::lround(midi));
    r.cents = (midi - r.note) * 100.0;
    return r;
}

// ── The loop pedal ─────────────────────────────────────────────────────────────────────────────────────────

LooperPedal::LooperPedal() : Pedal(PedalKind::Looper) {}

void LooperPedal::prepare(float sample_rate) {
    if (sample_rate != sr_ || heard_.empty()) {
        looper_.reset();
        memory_[0].reset();
        memory_[1].reset();
        capacity_ = 0;
    }
    Pedal::prepare(sample_rate);
    heard_.assign(kMaxPedalBlock, 0.0f);
}

bool LooperPedal::allocate(double seconds) {
    if (memory_[0]) return false;
    capacity_ = int64_t(seconds * sr_);
    memory_[0].reset(new float[size_t(capacity_)]());
    memory_[1].reset(new float[size_t(capacity_)]());
    return true;
}

void LooperPedal::update() {
    looper_.setLevel(levelKnob(control(0)));
    looper_.setSync(control(1) > 0.5f);
    looper_.setDubAfterRecord(control(2) > 0.5f);
}

void LooperPedal::runTrails(float* io, int n, float, float, const PedalTiming& timing) {
    n = std::min(n, int(heard_.size()));
    std::copy(io, io + n, heard_.begin());
    looper_.process(heard_.data(), io, n, timing.next_bar, timing.bar);  // adds the loop to what passes through
}

// ── The plug-in pedal ──────────────────────────────────────────────────────────────────────────────────────

PluginPedal::PluginPedal(std::unique_ptr<PluginInstance> plugin) : Pedal(PedalKind::Plugin), plugin_(std::move(plugin)) {}

PluginPedal::~PluginPedal() = default;

void PluginPedal::prepare(float sample_rate) {
    Pedal::prepare(sample_rate);
    error_.clear();
    ready_ = plugin_ && plugin_->prepare(sample_rate, 4096, &error_, stereo_);
}

void PluginPedal::run(float* io, int n, const PedalTiming& timing) {
    if (!ready_) return;
    if (timing.beat_samples > 0.0) plugin_->setTempo(60.0 * sr_ / timing.beat_samples);
    plugin_->process(io, n);
}

void PluginPedal::runStereo(float* left, float* right, int n, const PedalTiming& timing) {
    if (!ready_) return;
    if (timing.beat_samples > 0.0) plugin_->setTempo(60.0 * sr_ / timing.beat_samples);
    plugin_->processStereo(left, right, n);
}

}  // namespace sr
