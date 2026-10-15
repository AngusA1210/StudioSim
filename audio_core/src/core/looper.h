#pragma once

// A loop pedal, as sits on the floor in front of a guitar amp. One footswitch records a phrase, plays it round and
// round, and lays more on top (overdubs); Stop, Undo/Redo of the last overdub, and Clear do the rest. With Sync on,
// recordings start and end on bar lines while the patterns are running, so the loop stays in time with them.
//
// It records the signal on its way into the amp, so the loop plays back through the amp's current settings.
// Runs on the audio thread and never allocates: the game thread hands it two buffers before the first recording.

#include <atomic>
#include <cstdint>

namespace sr {

class Looper {
public:
    enum State : int { Empty, Waiting, Recording, Playing, Overdubbing, Stopped };
    enum Action : int { Press, Stop, Play, Undo, Redo, Clear };

    // The memory to record into: two buffers of `capacity` samples each (the loop, and the loop as it was before
    // the last overdub, for Undo). Only while the looper is not running on another thread, or through a command.
    void setMemory(float* a, float* b, int64_t capacity);
    void reset();  // back to empty, forgetting its memory (the sample rate changed)

    // Audio thread.
    void setLevel(float gain) { level_ = gain; }
    void setSync(bool on) { sync_ = on; }
    void setDubAfterRecord(bool on) { dub_after_ = on; }
    void act(Action action);
    // Adds the loop's playback for these `n` samples to `out`, recording from `in` as its state says. `next_bar` is
    // how many samples until the next bar line (-1 while the patterns are stopped) and `bar` the length of a bar.
    void process(const float* in, float* out, int n, int64_t next_bar, int64_t bar);

    // Any thread.
    State state() const { return State(state_out_.load(std::memory_order_relaxed)); }
    int64_t length() const { return length_out_.load(std::memory_order_relaxed); }
    int64_t position() const { return position_out_.load(std::memory_order_relaxed); }
    bool canUndo() const { return undo_out_.load(std::memory_order_relaxed); }
    bool canRedo() const { return redo_out_.load(std::memory_order_relaxed); }
    int64_t capacity() const { return capacity_; }

private:
    void startRecording();
    void closeFirstTake();
    void startOverdub();
    void endOverdub();
    bool written(int64_t pos) const;  // this overdub session has already reached `pos` in the new layer
    void publish();

    float* buf_[2] = {nullptr, nullptr};
    int64_t capacity_ = 0;
    int current_ = 0;  // which buffer holds the loop; the other is the new layer being built, or the one before it
    State state_ = Empty;
    int64_t length_ = 0, pos_ = 0;
    bool take_on_bars_ = false;    // the first take started on a bar line, so it ends on one
    bool finish_asked_ = false;    // ...and the footswitch has asked it to
    int64_t take_end_ = -1;        // the length it will end at, once known
    // An overdub session builds the new layer in the other buffer: positions it has reached hold the old loop plus
    // what was played over it; positions it hasn't still need the old loop copying across, which carries on in the
    // background after the session ends until the new layer is complete.
    bool session_ = false;
    int64_t session_start_ = 0, session_written_ = 0;
    bool overdub_queued_ = false;  // asked for while the last session was still being completed
    bool can_undo_ = false, can_redo_ = false;
    bool sync_ = false, dub_after_ = false;
    float level_ = 1.0f, level_now_ = 1.0f;

    std::atomic<int> state_out_{Empty};
    std::atomic<int64_t> length_out_{0}, position_out_{0};
    std::atomic<bool> undo_out_{false}, redo_out_{false};
};

}  // namespace sr
