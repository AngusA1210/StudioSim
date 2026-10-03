#include "sequencer.h"

namespace sr {
namespace {

struct Chord {
    int root;
    int pad[4];
    int tones[6];
};

// Am7 · Fmaj7 · Cmaj7 · G6: all white keys, so anything played on the Keys fits.
constexpr Chord kChords[4] = {
    {45, {55, 57, 60, 64}, {69, 72, 76, 79, 81, 84}},
    {41, {53, 57, 60, 64}, {69, 72, 76, 77, 81, 84}},
    {48, {55, 59, 60, 64}, {67, 71, 72, 76, 79, 84}},
    {43, {55, 59, 62, 64}, {67, 71, 74, 76, 79, 83}},
};

// step → semitones above the chord root and length in steps (length 0 = no note)
constexpr float kBass[16][2] = {{0, 3}, {0, 0}, {0, 0}, {0, 0}, {0, 0}, {0, 0}, {0, 1.5f}, {0, 0},
                                {12, 1}, {0, 0}, {0, 2.5f}, {0, 0}, {0, 0}, {0, 0}, {7, 1.5f}, {0, 0}};

constexpr int kBells[2][16] = {
    {0, -1, 2, -1, 3, -1, 2, 1, -1, 4, -1, 2, -1, 3, -1, -1},
    {1, -1, 3, -1, 2, -1, 4, -1, 5, -1, 3, -1, 2, -1, 1, -1},
};

}  // namespace

void Sequencer::setSampleRate(double sr) {
    sr_ = sr;
    step_samples_ = 60.0 / kBpm / 4.0 * sr;
    next_step_ = 0;
    next_step_time_ = 0.2 * sr;  // a short breath before the first downbeat
}

void Sequencer::process(int64_t block_end, SequencerSink& sink) {
    if (!running_) return;
    while (next_step_time_ < double(block_end)) {
        scheduleStep(next_step_, next_step_time_, sink);
        ++next_step_;
        next_step_time_ += step_samples_;
    }
}

void Sequencer::scheduleStep(int64_t n, double t0, SequencerSink& sink) {
    const int s = int(n % 16), bar = int((n / 16) % 4);
    const Chord& chord = kChords[bar];
    const double t = t0 + (s % 2 ? step_samples_ * kSwing : 0.0);
    const float step_sec = float(step_samples_ / sr_);

    if (s == 0 || s == 6 || s == 10 || (bar == 3 && s == 13)) sink.kick(t, s == 0 ? 1.0f : 0.8f);
    if (s == 4 || s == 12) sink.snare(t, 0.9f);
    if (bar == 3 && s == 15) sink.snare(t, 0.3f);
    if (s % 2 == 0) sink.hat(t, s % 4 == 0 ? 0.6f : 0.4f, bar % 2 == 1 && s == 14);
    else if (rng_.uniform() < 0.25f) sink.hat(t, 0.2f, false);

    if (kBass[s][1] > 0) sink.bass(t, chord.root + int(kBass[s][0]), kBass[s][1] * step_sec, 0.8f);
    if (s == 0) sink.pad(t0, chord.pad, 4, 16 * step_sec, 0.07f);

    const int b = kBells[bar % 2][s];
    if (b >= 0) sink.bell(t, chord.tones[b], 0.45f + (s % 4 == 0 ? 0.2f : 0.0f) + rng_.uniform() * 0.1f);
}

}  // namespace sr
