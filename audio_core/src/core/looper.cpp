#include "looper.h"

#include <algorithm>
#include <cstring>

namespace sr {
namespace {

constexpr int64_t kFade = 120;           // samples faded at each end of the first take, so the loop point doesn't click
constexpr int64_t kCopyPerBlock = 262144;  // how much of the old loop is copied into a new layer per block, at most

}  // namespace

void Looper::setMemory(float* a, float* b, int64_t capacity) {
    buf_[0] = a;
    buf_[1] = b;
    capacity_ = capacity;
}

void Looper::reset() {
    buf_[0] = buf_[1] = nullptr;
    capacity_ = 0;
    act(Clear);
}

void Looper::act(Action action) {
    switch (action) {
        case Press:
            switch (state_) {
                case Empty:
                    if (capacity_ > 0) startRecording();
                    break;
                case Waiting:
                    state_ = Empty;  // changed your mind before the bar line
                    break;
                case Recording:
                    if (take_on_bars_) finish_asked_ = true;  // finish on the next bar line (process works out where)
                    else closeFirstTake();
                    break;
                case Playing:
                    startOverdub();
                    break;
                case Overdubbing:
                    endOverdub();
                    break;
                case Stopped:
                    state_ = Playing;
                    pos_ = 0;
                    break;
            }
            break;
        case Stop:
            if (state_ == Recording) closeFirstTake();
            if (state_ == Overdubbing) endOverdub();
            if (state_ == Waiting) state_ = Empty;
            if (state_ == Playing) state_ = Stopped;
            pos_ = 0;
            overdub_queued_ = false;
            break;
        case Play:
            if (state_ == Stopped) {
                state_ = Playing;
                pos_ = 0;
            }
            break;
        case Undo:
            if (session_) {  // the overdub in progress, or still being completed: throw it away
                session_ = false;
                overdub_queued_ = false;
                if (state_ == Overdubbing) state_ = Playing;
            } else if (can_undo_) {
                current_ = 1 - current_;
                can_undo_ = false;
                can_redo_ = true;
            }
            break;
        case Redo:
            if (can_redo_ && !session_) {
                current_ = 1 - current_;
                can_redo_ = false;
                can_undo_ = true;
            }
            break;
        case Clear:
            state_ = Empty;
            length_ = pos_ = 0;
            session_ = overdub_queued_ = false;
            can_undo_ = can_redo_ = false;
            current_ = 0;
            break;
    }
    publish();
}

void Looper::startRecording() {
    state_ = sync_ ? Waiting : Recording;  // with Sync, process() starts it on the next bar line (or now, if there are none)
    pos_ = length_ = 0;
    take_on_bars_ = finish_asked_ = false;
    take_end_ = -1;
    current_ = 0;
    can_undo_ = can_redo_ = false;
    session_ = false;
}

void Looper::closeFirstTake() {
    length_ = std::max<int64_t>(pos_, 1);
    float* loop = buf_[current_];
    const int64_t fade = std::min(kFade, length_ / 4);
    for (int64_t i = 0; i < fade; ++i) {
        const float g = float(i) / float(fade);
        loop[i] *= g;
        loop[length_ - 1 - i] *= g;
    }
    pos_ = 0;
    state_ = Playing;
    if (dub_after_) startOverdub();
}

void Looper::startOverdub() {
    if (session_) {  // the last overdub's new layer isn't finished yet: start as soon as it is
        overdub_queued_ = true;
        return;
    }
    session_ = true;
    session_start_ = pos_;
    session_written_ = 0;
    can_redo_ = false;
    state_ = Overdubbing;
}

void Looper::endOverdub() {
    state_ = Playing;  // the rest of the old loop is copied into the new layer in the background
}

bool Looper::written(int64_t pos) const {
    return session_ && (pos - session_start_ + length_) % length_ < session_written_;
}

void Looper::process(const float* in, float* out, int n, int64_t next_bar, int64_t bar) {
    const bool bars = next_bar >= 0 && bar > 0;  // the patterns are running, so there are bar lines to keep to
    int64_t until_bar = next_bar;
    for (int i = 0; i < n; ++i, --until_bar) {
        if (bars && until_bar < 0) until_bar += bar;
        level_now_ += (level_ - level_now_) * 0.002f;
        if (state_ == Waiting) {
            if (bars && until_bar != 0) continue;
            state_ = Recording;  // on the bar line, or straight away if there are none
            take_on_bars_ = bars;
        }
        switch (state_) {
            case Recording:
                if (finish_asked_ && take_end_ < 0 && bars) take_end_ = std::max<int64_t>(1, (pos_ + bar - 1) / bar) * bar;
                if (finish_asked_ && !bars) take_end_ = pos_;  // the patterns stopped meanwhile: finish now
                if ((take_end_ >= 0 && pos_ >= take_end_) || pos_ >= capacity_) {
                    closeFirstTake();
                    break;
                }
                buf_[current_][pos_++] = in[i];
                length_ = pos_;
                break;
            case Playing:
            case Overdubbing: {
                float* old_loop = buf_[current_];
                float* new_layer = buf_[1 - current_];
                const float sounding = written(pos_) ? new_layer[pos_] : old_loop[pos_];
                out[i] += sounding * level_now_;
                if (state_ == Overdubbing) {
                    new_layer[pos_] = sounding + in[i];
                    if (session_written_ < length_) ++session_written_;  // the session has now reached this position
                }
                if (++pos_ >= length_) pos_ = 0;
                break;
            }
            default:
                break;
        }
    }
    // The background copy: the parts of the old loop the session didn't reach, into the new layer.
    if (session_ && state_ != Overdubbing && length_ > 0) {
        float* old_loop = buf_[current_];
        float* new_layer = buf_[1 - current_];
        int64_t todo = std::min(kCopyPerBlock, length_ - session_written_);
        while (todo > 0) {
            const int64_t at = (session_start_ + session_written_) % length_;
            const int64_t run = std::min(todo, length_ - at);
            std::memcpy(new_layer + at, old_loop + at, sizeof(float) * size_t(run));
            session_written_ += run;
            todo -= run;
        }
        if (session_written_ >= length_) {  // the new layer is complete: it becomes the loop
            session_ = false;
            current_ = 1 - current_;
            can_undo_ = true;
            if (overdub_queued_) {
                overdub_queued_ = false;
                if (state_ == Playing) startOverdub();
            }
        }
    }
    publish();
}

void Looper::publish() {
    state_out_.store(state_, std::memory_order_relaxed);
    length_out_.store(state_ == Recording || state_ == Waiting ? pos_ : length_, std::memory_order_relaxed);
    position_out_.store(pos_, std::memory_order_relaxed);
    undo_out_.store(session_ || can_undo_, std::memory_order_relaxed);
    redo_out_.store(can_redo_ && !session_, std::memory_order_relaxed);
}

}  // namespace sr
