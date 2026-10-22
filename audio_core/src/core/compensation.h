#pragma once

// The delay that delay compensation is made of: a sound held back by a whole number of samples, so that it meets
// another that a plug-in has made late. Made on the game thread (it is large), played on the audio thread; a change of
// delay takes effect at once.

#include <vector>

namespace sr {

class CompensationDelay {
public:
    static constexpr int kMaxDelay = 16384;  // samples (a third of a second at 48 kHz)

    CompensationDelay() : l_(kSize, 0.0f), r_(kSize, 0.0f) {}

    // In place, `delay` samples late (up to kMaxDelay). `r` may be null, for one channel.
    void process(float* l, float* r, int n, int delay) {
        feed(l, r, n);
        read(l, r, n, delay, n);
    }
    // Remembers what arrives, without giving anything back yet (`r` may be null).
    void feed(const float* l, const float* r, int n) {
        for (int i = 0; i < n; ++i) {
            l_[size_t((pos_ + i) & kMask)] = l[i];
            if (r) r_[size_t((pos_ + i) & kMask)] = r[i];
        }
        pos_ = (pos_ + n) & kMask;
    }
    // What arrived `back` samples before the end of what was last fed, onwards, `delay` samples late.
    void read(float* l, float* r, int n, int delay, int back) const {
        delay = delay < 0 ? 0 : (delay > kMaxDelay ? kMaxDelay : delay);
        for (int i = 0; i < n; ++i) {
            const size_t at = size_t((pos_ - back + i - delay) & kMask);
            l[i] = l_[at];
            if (r) r[i] = r_[at];
        }
    }

private:
    static constexpr int kSize = 32768;  // a power of two, with room for the longest delay and a block
    static constexpr int kMask = kSize - 1;
    std::vector<float> l_, r_;
    int pos_ = 0;
};

}  // namespace sr
