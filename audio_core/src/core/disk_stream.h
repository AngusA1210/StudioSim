#pragma once

// Audio files read from disk as they play, as a DAW reads its tracks. A WAV is opened by its header alone, and its
// audio is read in chunks (mixed down to one channel, as floats) by a disk thread a few seconds ahead of where the
// music will be, round the loop too. Chunks stay in memory while there is room for them; past a budget, those needed
// longest ago are let go. A room hours long then needs only what is about to play in memory.

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace sr {

class StreamedFile {
public:
    static constexpr int kChunkShift = 15;
    static constexpr size_t kChunkFrames = size_t(1) << kChunkShift;  // 32768 frames: 0.68 s at 48 kHz

    // Reads a WAV's header (16-, 24- or 32-bit integers, or 32-bit float; any number of channels). Null, with the
    // reason, if it can't be read.
    static std::shared_ptr<StreamedFile> open(const std::string& path, std::string* error);
    ~StreamedFile();
    StreamedFile(const StreamedFile&) = delete;
    StreamedFile& operator=(const StreamedFile&) = delete;

    const std::string& path() const { return path_; }
    double rate() const { return rate_; }
    int64_t frames() const { return frames_; }
    double seconds() const { return rate_ > 0.0 ? double(frames_) / rate_ : 0.0; }
    size_t chunkCount() const { return chunk_count_; }
    // Whether the file on disk is still as it was when it was opened (its size, and when it was last written).
    bool unchanged() const;

    // Audio thread: chunk `i` (kChunkFrames samples; the last, fewer), or null while it isn't in memory.
    const float* chunk(size_t i) const { return i < chunk_count_ ? chunks_[i].load(std::memory_order_acquire) : nullptr; }
    bool loaded(size_t i) const { return chunk(i) != nullptr; }
    // Reads chunk `i` in, if it isn't in already: the disk thread, the game thread getting ready to play, or the audio
    // thread when rendering offline (it can wait). Returns whether it is in memory now.
    bool load(size_t i);
    // The disk thread takes chunk `i` out, and is handed its memory to free once the audio thread can't still be
    // reading it. Null if it wasn't in.
    float* unload(size_t i);
    // Reads `count` frames from `from`, mixed down to one channel, without keeping them (any thread). Returns how many.
    size_t read(int64_t from, size_t count, float* out);

private:
    StreamedFile() = default;
    size_t readLocked(int64_t from, size_t count, float* out);

    std::string path_;
    int format_ = 0, channels_ = 0, bits_ = 0;
    double rate_ = 0.0;
    int64_t frames_ = 0, data_offset_ = 0;
    uintmax_t size_on_disk_ = 0;
    int64_t written_at_ = 0;
    size_t chunk_count_ = 0;
    std::unique_ptr<std::atomic<float*>[]> chunks_;
    std::mutex reading_;  // one reader of the file at a time, and loading a chunk only once
    std::vector<uint8_t> raw_;
};

// One audio clip's file, as the disk thread needs to know of it: placed `start` seconds into the timeline, from `offset`
// seconds into the file, `length` long.
struct StreamRegion {
    std::shared_ptr<StreamedFile> file;
    double start = 0.0, offset = 0.0, length = 0.0;
};

class DiskStreamer {
public:
    static constexpr double kAheadSeconds = 4.0;   // read this far ahead of the music
    static constexpr double kBehindSeconds = 0.5;  // and keep this much behind it
    static constexpr size_t kDefaultBudget = size_t(256) << 20;  // bytes of audio kept in memory beyond what is needed

    DiskStreamer();
    ~DiskStreamer();  // stops the disk thread
    DiskStreamer(const DiskStreamer&) = delete;
    DiskStreamer& operator=(const DiskStreamer&) = delete;

    // Game thread: a track's clips (replacing what it had), and what may stay in memory beyond what is needed.
    void setRegions(int track, std::vector<StreamRegion> regions);
    void setBudget(size_t bytes);
    // Game thread: reads what plays from `seconds` for the next `for_seconds`, before the music starts there, and keeps
    // it in while stopped.
    void prepare(double seconds, double for_seconds = 0.5);
    // Audio thread, each block: where the music is on the timeline (seconds), and the loop it goes round.
    void follow(double seconds, bool playing, bool looping, double loop_from, double loop_to);
    // Audio thread: a block is done (chunks taken out are freed two blocks on); a sample wasn't in memory when wanted.
    void blockDone() { blocks_.fetch_add(1, std::memory_order_acq_rel); }
    void missed() { misses_.fetch_add(1, std::memory_order_relaxed); }

    uint64_t misses() const { return misses_.load(std::memory_order_relaxed); }
    size_t bytesInMemory() const { return in_memory_.load(std::memory_order_relaxed); }
    // Waits for the disk thread to go round once more (the offline checks).
    void settle();

private:
    struct Known {  // a file the disk thread has seen, and when each of its chunks was last needed
        std::weak_ptr<StreamedFile> file;
        std::vector<uint64_t> needed_at;
    };
    void run();
    void cycle();
    void freeRetired(bool all);

    std::mutex regions_lock_;
    std::unordered_map<int, std::vector<StreamRegion>> regions_;
    double cue_from_ = -1.0, cue_to_ = -1.0;
    size_t budget_ = kDefaultBudget;

    std::atomic<double> now_{0.0}, loop_from_{0.0}, loop_to_{0.0};
    std::atomic<bool> playing_{false}, looping_{false};
    std::atomic<uint64_t> blocks_{0}, misses_{0}, cycles_{0};
    std::atomic<size_t> in_memory_{0};

    std::unordered_map<const StreamedFile*, Known> known_;  // the disk thread's
    std::vector<std::pair<float*, uint64_t>> retired_;     // chunks taken out, and the block count then
    uint64_t cycle_ = 0;

    std::mutex wake_lock_;
    std::condition_variable wake_;
    bool quit_ = false, poke_ = false;
    std::thread thread_;
};

}  // namespace sr
