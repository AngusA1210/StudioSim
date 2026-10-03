#pragma once

// The shared clock and the prototype's four-bar groove. Time is counted in samples on the audio thread,
// and each event is placed at its exact sample, so it plays in time regardless of block boundaries.
// When the network arrives this clock becomes the session clock that every player syncs to.

#include <cstdint>

#include "dsp.h"

namespace sr {

// Receives the sequencer's events. `at` is an absolute sample position on the engine clock.
class SequencerSink {
public:
    virtual ~SequencerSink() = default;
    virtual void kick(double at, float velocity) = 0;
    virtual void snare(double at, float velocity) = 0;
    virtual void hat(double at, float velocity, bool open) = 0;
    virtual void bass(double at, int note, float dur_sec, float velocity) = 0;
    virtual void pad(double at, const int* notes, int count, float dur_sec, float velocity) = 0;
    virtual void bell(double at, int note, float velocity) = 0;
};

class Sequencer {
public:
    static constexpr double kBpm = 92.0;
    static constexpr double kSwing = 0.14;  // odd sixteenths land this fraction of a step late

    void setSampleRate(double sr);
    void setRunning(bool running) { running_ = running; }
    bool running() const { return running_; }

    // Emits every step that starts before `block_end` (and has not been emitted yet).
    void process(int64_t block_end, SequencerSink& sink);

    double stepSamples() const { return step_samples_; }

private:
    void scheduleStep(int64_t step, double at, SequencerSink& sink);

    double sr_ = 48000.0, step_samples_ = 0.0, next_step_time_ = 0.0;
    int64_t next_step_ = 0;
    bool running_ = true;
    Rng rng_{0x6C078965u};
};

}  // namespace sr
