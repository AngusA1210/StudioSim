#include "recorder.h"

#include <algorithm>
#include <chrono>

namespace sr {
namespace {
constexpr size_t kRing = size_t(1) << 20;  // about 20 seconds at 48 kHz, should the disk ever stall
}

bool Recorder::begin(const std::vector<std::pair<int, std::string>>& tracks, int sample_rate, std::string* error,
                     const std::vector<int>& stereo) {
    finish();
    tracks_.clear();
    takes_.clear();
    for (const auto& [source, path] : tracks) {
        auto track = std::make_unique<Track>();
        track->source = source;
        track->channels = std::find(stereo.begin(), stereo.end(), source) != stereo.end() ? 2 : 1;
        track->ring.assign(kRing, 0.0f);
        if (!track->wav.open(path, sample_rate, error, track->channels)) {
            tracks_.clear();
            return false;
        }
        takes_.push_back({source, path, 0, 0});
        tracks_.push_back(std::move(track));
    }
    running_.store(true);
    writer_ = std::thread([this] { run(); });
    return true;
}

int Recorder::slotOf(int source) const {
    for (size_t i = 0; i < tracks_.size(); ++i)
        if (tracks_[i]->source == source) return int(i);
    return -1;
}

void Recorder::write(int slot, const float* x, int n) {
    if (slot < 0 || slot >= int(tracks_.size())) return;
    Track& t = *tracks_[size_t(slot)];
    const size_t head = t.head.load(std::memory_order_relaxed), tail = t.tail.load(std::memory_order_acquire);
    const size_t space = kRing - (head - tail);
    const size_t take = std::min(space, size_t(n));
    for (size_t i = 0; i < take; ++i) t.ring[(head + i) & (kRing - 1)] = x[i];
    t.head.store(head + take, std::memory_order_release);
    if (take < size_t(n)) t.dropped.fetch_add(int64_t(size_t(n) - take), std::memory_order_relaxed);
}

void Recorder::write(int slot, const float* left, const float* right, int n) {
    if (slot < 0 || slot >= int(tracks_.size())) return;
    Track& t = *tracks_[size_t(slot)];
    if (t.channels < 2) {
        write(slot, left, n);
        return;
    }
    const size_t head = t.head.load(std::memory_order_relaxed), tail = t.tail.load(std::memory_order_acquire);
    const size_t space = (kRing - (head - tail)) / 2;
    const size_t take = std::min(space, size_t(n));
    for (size_t i = 0; i < take; ++i) {
        t.ring[(head + 2 * i) & (kRing - 1)] = left[i];
        t.ring[(head + 2 * i + 1) & (kRing - 1)] = right[i];
    }
    t.head.store(head + 2 * take, std::memory_order_release);
    if (take < size_t(n)) t.dropped.fetch_add(int64_t(size_t(n) - take), std::memory_order_relaxed);
}

void Recorder::drain() {
    std::vector<float> chunk;
    for (auto& t : tracks_) {
        const size_t tail = t->tail.load(std::memory_order_relaxed), head = t->head.load(std::memory_order_acquire);
        if (head == tail) continue;
        chunk.resize(head - tail);
        for (size_t i = 0; i < chunk.size(); ++i) chunk[i] = t->ring[(tail + i) & (kRing - 1)];
        t->wav.write(chunk.data(), chunk.size());
        t->tail.store(head, std::memory_order_release);
    }
}

void Recorder::run() {
    while (running_.load()) {
        drain();
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    drain();
}

void Recorder::finish() {
    if (writer_.joinable()) {
        running_.store(false);
        writer_.join();
    }
    for (size_t i = 0; i < tracks_.size(); ++i) {
        tracks_[i]->wav.close();
        takes_[i].frames = tracks_[i]->wav.frames();
        takes_[i].dropped = tracks_[i]->dropped.load();
    }
}

}  // namespace sr
