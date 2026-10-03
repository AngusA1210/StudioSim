#pragma once

#include <atomic>
#include <cstddef>
#include <vector>

namespace sr {

// Lock-free single-producer / single-consumer ring buffer.
// The game thread pushes commands; the audio thread pops them at the start of each block.
template <typename T>
class SpscQueue {
public:
    explicit SpscQueue(size_t capacity_pow2) : buf_(capacity_pow2), mask_(capacity_pow2 - 1) {}

    bool push(const T& value) {
        const size_t head = head_.load(std::memory_order_relaxed);
        if (head - tail_.load(std::memory_order_acquire) == buf_.size()) return false;  // full
        buf_[head & mask_] = value;
        head_.store(head + 1, std::memory_order_release);
        return true;
    }

    bool pop(T& out) {
        const size_t tail = tail_.load(std::memory_order_relaxed);
        if (tail == head_.load(std::memory_order_acquire)) return false;  // empty
        out = buf_[tail & mask_];
        tail_.store(tail + 1, std::memory_order_release);
        return true;
    }

private:
    std::vector<T> buf_;
    size_t mask_;
    alignas(64) std::atomic<size_t> head_{0};
    alignas(64) std::atomic<size_t> tail_{0};
};

}  // namespace sr
