#include "sequencer.h"

#include <algorithm>
#include <cmath>

namespace sr {
namespace {

struct Chord {
    int root;
    int pad[4];
    int tones[6];
};

// Am7 · Fmaj7 · Cmaj7 · G6, one bar each.
constexpr Chord kChords[4] = {
    {45, {55, 57, 60, 64}, {69, 72, 76, 79, 81, 84}},
    {41, {53, 57, 60, 64}, {69, 72, 76, 77, 81, 84}},
    {48, {55, 59, 60, 64}, {67, 71, 72, 76, 79, 84}},
    {43, {55, 59, 62, 64}, {67, 71, 74, 76, 79, 83}},
};

// step → semitones above the chord root and length in steps (length 0 = no note)
constexpr float kBass[16][2] = {{0, 3}, {0, 0}, {0, 0}, {0, 0}, {0, 0}, {0, 0}, {0, 1.5f}, {0, 0},
                                {12, 1}, {0, 0}, {0, 2.5f}, {0, 0}, {0, 0}, {0, 0}, {7, 1.5f}, {0, 0}};

// step → which chord tone the bells play (-1 = rest); the two bars alternate
constexpr int kBells[2][16] = {
    {0, -1, 2, -1, 3, -1, 2, 1, -1, 4, -1, 2, -1, 3, -1, -1},
    {1, -1, 3, -1, 2, -1, 4, -1, 5, -1, 3, -1, 2, -1, 1, -1},
};

}  // namespace

std::vector<PatternNote> defaultPattern(InstrumentKind kind) {
    std::vector<PatternNote> out;
    auto add = [&](int step, int note, float length, float velocity, float chance = 1.0f) {
        out.push_back({step, note, length, velocity, chance});
    };
    const int kick = Drums::noteFor(Drums::Kick), snare = Drums::noteFor(Drums::Snare);
    const int hat = Drums::noteFor(Drums::HatClosed), open_hat = Drums::noteFor(Drums::HatOpen);
    for (int bar = 0; bar < 4; ++bar) {
        const Chord& chord = kChords[bar];
        for (int s = 0; s < kStepsPerBar; ++s) {
            const int step = bar * kStepsPerBar + s;
            switch (kind) {
                case InstrumentKind::Drums:
                    if (s == 0 || s == 6 || s == 10 || (bar == 3 && s == 13)) add(step, kick, 1, s == 0 ? 1.0f : 0.8f);
                    if (s == 4 || s == 12) add(step, snare, 1, 0.9f);
                    if (bar == 3 && s == 15) add(step, snare, 1, 0.3f);
                    if (s % 2 == 0) add(step, bar % 2 == 1 && s == 14 ? open_hat : hat, 1, s % 4 == 0 ? 0.6f : 0.4f);
                    else add(step, hat, 1, 0.2f, 0.25f);  // a ghost note, one time in four
                    break;
                case InstrumentKind::Bass:
                    if (kBass[s][1] > 0) add(step, chord.root + int(kBass[s][0]), kBass[s][1], 0.8f);
                    break;
                case InstrumentKind::Pad:
                    if (s == 0)
                        for (int note : chord.pad) add(step, note, float(kStepsPerBar), 0.8f);
                    break;
                case InstrumentKind::Bells:
                    if (kBells[bar % 2][s] >= 0) add(step, chord.tones[kBells[bar % 2][s]], 1, 0.45f + (s % 4 == 0 ? 0.2f : 0.0f));
                    break;
                default:  // the Keys, and everything that plays an input
                    break;
            }
        }
    }
    return out;
}

void Sequencer::setSampleRate(double sr) {
    sr_ = sr;
    step_samples_ = 60.0 / bpm_ / 4.0 * sr;
    next_step_ = 0;
    next_step_time_ = 0.2 * sr;  // a short breath before the first downbeat
}

void Sequencer::retime(double sr, int64_t now) {
    sr_ = sr;
    step_samples_ = 60.0 / bpm_ / 4.0 * sr;
    next_step_time_ = double(now) + 0.05 * sr;
}

void Sequencer::setTempo(double bpm) {
    bpm_ = std::clamp(bpm, kMinBpm, kMaxBpm);
    step_samples_ = 60.0 / bpm_ / 4.0 * sr_;  // takes effect from the next step
}

void Sequencer::setSwing(double swing) { swing_ = std::clamp(swing, 0.0, 0.6); }

void Sequencer::start(int64_t now, int64_t from_step) {
    running_ = true;
    next_step_ = std::max<int64_t>(from_step, 0);
    next_step_time_ = double(now) + 0.02 * sr_;
    wrapped_at_ = -1.0;
}

void Sequencer::stop(int64_t now) {
    if (running_) stopped_at_ = position(now);
    running_ = false;
}

void Sequencer::setLoop(bool on, int64_t start, int64_t end) {
    loop_on_ = on && end > start;
    loop_start_ = start;
    loop_end_ = end;
}

double Sequencer::position(int64_t at) const {
    if (!running_ || step_samples_ <= 0.0) return stopped_at_;
    double steps = double(next_step_) - (next_step_time_ - double(at)) / step_samples_;
    if (wrapped_at_ >= 0.0 && double(at) < wrapped_at_ && loop_on_) steps += double(loop_end_ - loop_start_);  // just before the jump
    return std::max(steps, 0.0);
}

int64_t Sequencer::nextBarAt(int64_t from) const {
    if (!running_ || step_samples_ <= 0.0) return -1;
    // Steps fall every step_samples_ either side of the next one due; bars begin on every sixteenth step.
    int64_t step = next_step_ - int64_t(std::floor((next_step_time_ - double(from)) / step_samples_));
    while (next_step_time_ + double(step - next_step_) * step_samples_ < double(from)) ++step;
    step = (step + kStepsPerBar - 1) / kStepsPerBar * kStepsPerBar;
    if (step < 0) step = 0;
    return int64_t(std::llround(next_step_time_ + double(step - next_step_) * step_samples_));
}

void Sequencer::process(int64_t block_end, StepSink& sink) {
    if (!running_) return;
    while (next_step_time_ < double(block_end)) {
        sink.step(next_step_, next_step_time_ + (next_step_ % 2 ? step_samples_ * swing_ : 0.0), step_samples_);
        ++next_step_;
        next_step_time_ += step_samples_;
        if (loop_on_ && !loop_suspended_ && next_step_ == loop_end_) {  // back to the loop's start
            next_step_ = loop_start_;
            wrapped_at_ = next_step_time_;
        }
    }
}

}  // namespace sr
