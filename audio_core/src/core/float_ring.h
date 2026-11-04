#pragma once

// Samples from one thread to another, neither waiting (a single producer and a single consumer): what the network
// brings in (net_audio.h), what the computer's other apps play (desktop_audio.h).

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <vector>

namespace sr {

class FloatRing {
public:
    explicit FloatRing(size_t capacity_pow2) : buf_(capacity_pow2, 0.0f), mask_(capacity_pow2 - 1) {}
    size_t write(const float* in, size_t n) {  // as many as there is room for (the producer)
        const size_t head = head_.load(std::memory_order_relaxed);
        const size_t room = buf_.size() - (head - tail_.load(std::memory_order_acquire));
        const size_t take = std::min(n, room);
        for (size_t i = 0; i < take; ++i) buf_[(head + i) & mask_] = in[i];
        head_.store(head + take, std::memory_order_release);
        return take;
    }
    size_t room() const { return buf_.size() - (head_.load(std::memory_order_relaxed) - tail_.load(std::memory_order_acquire)); }  // (producer)
    size_t available() const { return head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_relaxed); }
    float at(size_t i) const { return buf_[(tail_.load(std::memory_order_relaxed) + i) & mask_]; }  // the i-th unread
    void skip(size_t n) { tail_.store(tail_.load(std::memory_order_relaxed) + n, std::memory_order_release); }
    void reset() { tail_.store(head_.load(std::memory_order_acquire), std::memory_order_release); }  // (consumer)

private:
    std::vector<float> buf_;
    size_t mask_;
    alignas(64) std::atomic<size_t> head_{0};
    alignas(64) std::atomic<size_t> tail_{0};
};

}  // namespace sr
