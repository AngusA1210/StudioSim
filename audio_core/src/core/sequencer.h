#pragma once

// The shared clock, and the patterns it plays. Time is counted in samples on the audio thread and each step is
// placed at its exact sample, so the music stays in time regardless of block boundaries. Every instrument has its
// own pattern of notes on a grid of sixteenths; the engine plays them as the clock reaches each step.
// When the network arrives this clock becomes the session clock that every player syncs to.

#include <cstdint>
#include <vector>

#include "instruments.h"

namespace sr {

constexpr int kStepsPerBar = 16;        // sixteenth notes, four beats to the bar
constexpr int kMaxPatternSteps = 64;    // four bars
constexpr int kMaxPatternNotes = 512;

struct PatternNote {
    int step = 0;           // sixteenths from the start of the pattern
    int note = 60;          // MIDI note; for the drums, which piece (see Drums::pieceFor)
    float length = 1.0f;    // in steps
    float velocity = 0.8f;  // 0 to 1
    float chance = 1.0f;    // how likely it is to play each time round (1 = always)
};

// The groove the room starts with: the prototype's four bars over Am7 · Fmaj7 · Cmaj7 · G6 (all white keys, so
// anything played over it fits). Instruments without a part get an empty pattern.
std::vector<PatternNote> defaultPattern(InstrumentKind kind);

// Told about each step as the clock reaches it. `at` is an absolute sample position on the engine clock, already
// moved later by the swing if it is an off-beat step.
class StepSink {
public:
    virtual ~StepSink() = default;
    virtual void step(int64_t index, double at, double step_samples) = 0;
};

class Sequencer {
public:
    static constexpr double kDefaultBpm = 92.0, kMinBpm = 40.0, kMaxBpm = 240.0;
    static constexpr double kDefaultSwing = 0.14;  // odd sixteenths land this fraction of a step late

    void setSampleRate(double sr);
    // The sample rate changed while playing: keep the place in the music, continuing from sample `now`.
    void retime(double sr, int64_t now);
    void setTempo(double bpm);
    void setSwing(double swing);
    void start(int64_t now);  // from the first step
    void stop() { running_ = false; }
    bool running() const { return running_; }

    // Reports every step that starts before `block_end` (and has not been reported yet).
    void process(int64_t block_end, StepSink& sink);
    // Where the first bar line at or after sample `from` falls (-1 while stopped), and how long a bar is.
    int64_t nextBarAt(int64_t from) const;
    double barSamples() const { return step_samples_ * kStepsPerBar; }

private:
    double sr_ = 48000.0, bpm_ = kDefaultBpm, swing_ = kDefaultSwing;
    double step_samples_ = 0.0, next_step_time_ = 0.0;
    int64_t next_step_ = 0;
    bool running_ = true;
};

}  // namespace sr
