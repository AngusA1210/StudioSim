#include "disk_stream.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>

namespace sr {
namespace {

uint32_t get32(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
uint16_t get16(const uint8_t* p) { return uint16_t(p[0] | p[1] << 8); }

int seekTo(std::FILE* f, int64_t at) {
#ifdef _WIN32
    return _fseeki64(f, at, SEEK_SET);
#else
    return fseeko(f, off_t(at), SEEK_SET);
#endif
}

int64_t writtenAt(const std::string& path) {
    std::error_code ec;
    const auto when = std::filesystem::last_write_time(path, ec);
    return ec ? 0 : int64_t(when.time_since_epoch().count());
}

}  // namespace

// ── A file ──────────────────────────────────────────────────────────────────────────────────────────────────

std::shared_ptr<StreamedFile> StreamedFile::open(const std::string& path, std::string* error) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) {
        if (error) *error = "it couldn't be opened: " + path;
        return nullptr;
    }
    std::error_code ec;
    const uintmax_t size = std::filesystem::file_size(path, ec);
    uint8_t head[12];
    if (ec || std::fread(head, 1, 12, f) != 12 || std::memcmp(head, "RIFF", 4) != 0 || std::memcmp(head + 8, "WAVE", 4) != 0) {
        std::fclose(f);
        if (error) *error = "it isn't a WAV file";
        return nullptr;
    }
    int format = 0, channels = 0, bits = 0;
    uint32_t rate = 0;
    int64_t data_at = -1, data_size = 0;
    for (int64_t at = 12; at + 8 <= int64_t(size);) {
        uint8_t h[8];
        if (seekTo(f, at) != 0 || std::fread(h, 1, 8, f) != 8) break;
        const uint32_t chunk_size = get32(h + 4);
        if (std::memcmp(h, "fmt ", 4) == 0 && chunk_size >= 16) {
            uint8_t body[40] = {};
            const size_t got = std::fread(body, 1, std::min<size_t>(chunk_size, sizeof(body)), f);
            if (got >= 16) {
                format = get16(body);
                channels = get16(body + 2);
                rate = get32(body + 4);
                bits = get16(body + 14);
                if (format == 0xFFFE && got >= 26) format = get16(body + 24);  // WAVE_FORMAT_EXTENSIBLE
            }
        } else if (std::memcmp(h, "data", 4) == 0) {
            data_at = at + 8;
            const int64_t room = int64_t(size) - data_at;
            data_size = chunk_size == 0 || int64_t(chunk_size) > room ? room : int64_t(chunk_size);  // (one still being written: what there is)
            if (format != 0) break;
        }
        at += 8 + int64_t(chunk_size) + (chunk_size & 1);
    }
    std::fclose(f);
    const bool float32 = format == 3 && bits == 32, pcm = format == 1 && (bits == 16 || bits == 24 || bits == 32);
    if (data_at < 0 || channels < 1 || rate == 0 || !(float32 || pcm)) {
        if (error) *error = "its kind of WAV can't be read";
        return nullptr;
    }
    std::shared_ptr<StreamedFile> file(new StreamedFile());
    file->path_ = path;
    file->format_ = format;
    file->channels_ = channels;
    file->bits_ = bits;
    file->kept_ = channels >= 2 ? 2 : 1;
    file->rate_ = double(rate);
    file->data_offset_ = data_at;
    file->frames_ = data_size / (int64_t(bits / 8) * channels);
    file->size_on_disk_ = size;
    file->written_at_ = writtenAt(path);
    file->chunk_count_ = size_t((file->frames_ + int64_t(kChunkFrames) - 1) >> kChunkShift);
    file->chunks_.reset(new std::atomic<float*>[file->chunk_count_]);
    for (size_t i = 0; i < file->chunk_count_; ++i) file->chunks_[i].store(nullptr, std::memory_order_relaxed);
    return file;
}

StreamedFile::~StreamedFile() {
    for (size_t i = 0; i < chunk_count_; ++i) delete[] chunks_[i].load(std::memory_order_relaxed);
}

bool StreamedFile::unchanged() const {
    std::error_code ec;
    const uintmax_t size = std::filesystem::file_size(path_, ec);
    return !ec && size == size_on_disk_ && writtenAt(path_) == written_at_;
}

bool StreamedFile::load(size_t i) {
    if (i >= chunk_count_) return false;
    std::lock_guard<std::mutex> lock(reading_);
    if (chunks_[i].load(std::memory_order_acquire)) return true;
    const int64_t from = int64_t(i) << kChunkShift;
    float* data = new float[kChunkFrames * size_t(kept_)]();  // (silent past what there is to read)
    readLocked(from, size_t(std::min<int64_t>(int64_t(kChunkFrames), frames_ - from)), data, true);
    chunks_[i].store(data, std::memory_order_release);
    return true;
}

float* StreamedFile::unload(size_t i) {
    if (i >= chunk_count_) return nullptr;
    std::lock_guard<std::mutex> lock(reading_);
    return chunks_[i].exchange(nullptr, std::memory_order_acq_rel);
}

size_t StreamedFile::read(int64_t from, size_t count, float* out) {
    std::lock_guard<std::mutex> lock(reading_);
    return readLocked(from, count, out);
}

// Reads frames mixed down to one channel; or, with `keep_channels`, as many as it keeps (its first two, interleaved).
size_t StreamedFile::readLocked(int64_t from, size_t count, float* out, bool keep_channels) {
    if (from < 0 || from >= frames_ || count == 0) return 0;
    count = size_t(std::min<int64_t>(int64_t(count), frames_ - from));
    std::FILE* f = std::fopen(path_.c_str(), "rb");  // (opened for each read: a room may have hundreds of files)
    if (!f) return 0;
    const size_t width = size_t(bits_ / 8), frame_bytes = width * size_t(channels_);
    raw_.resize(count * frame_bytes);
    size_t got = 0;
    if (seekTo(f, data_offset_ + from * int64_t(frame_bytes)) == 0) got = std::fread(raw_.data(), frame_bytes, count, f);
    std::fclose(f);
    const bool float32 = format_ == 3;
    auto sample = [&](size_t frame, int c) {
        const uint8_t* p = raw_.data() + frame * frame_bytes + size_t(c) * width;
        float v;
        if (float32) std::memcpy(&v, p, 4);
        else if (bits_ == 16) v = float(int16_t(get16(p))) / 32768.0f;
        else if (bits_ == 24) v = float(int32_t(uint32_t(p[0]) << 8 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 24) >> 8) / 8388608.0f;
        else v = float(int32_t(get32(p))) / 2147483648.0f;
        return v;
    };
    for (size_t i = 0; i < got; ++i) {
        if (keep_channels && kept_ == 2) {
            out[2 * i] = sample(i, 0);
            out[2 * i + 1] = sample(i, 1);
            continue;
        }
        float sum = 0.0f;
        for (int c = 0; c < channels_; ++c) sum += sample(i, c);
        out[i] = sum / float(channels_);
    }
    return got;
}

// ── The disk thread ─────────────────────────────────────────────────────────────────────────────────────────

DiskStreamer::DiskStreamer() : thread_([this] { run(); }) {}

DiskStreamer::~DiskStreamer() {
    {
        std::lock_guard<std::mutex> lock(wake_lock_);
        quit_ = true;
    }
    wake_.notify_all();
    thread_.join();
    freeRetired(true);  // (the audio thread is no longer reading anything by now)
}

void DiskStreamer::setRegions(int track, std::vector<StreamRegion> regions) {
    {
        std::lock_guard<std::mutex> lock(regions_lock_);
        if (regions.empty()) regions_.erase(track);
        else regions_[track] = std::move(regions);
    }
    std::lock_guard<std::mutex> lock(wake_lock_);
    poke_ = true;
    wake_.notify_all();
}

void DiskStreamer::setBudget(size_t bytes) {
    std::lock_guard<std::mutex> lock(regions_lock_);
    budget_ = bytes;
}

void DiskStreamer::prepare(double seconds, double for_seconds) {
    std::vector<StreamRegion> regions;
    {
        std::lock_guard<std::mutex> lock(regions_lock_);
        cue_from_ = seconds - kBehindSeconds;
        cue_to_ = seconds + kAheadSeconds;
        for (const auto& [track, list] : regions_) regions.insert(regions.end(), list.begin(), list.end());
    }
    for (const StreamRegion& r : regions) {
        const double a = std::max(seconds, r.start), b = std::min(seconds + for_seconds, r.start + r.length);
        if (!r.file || b <= a) continue;
        const int64_t first = std::max<int64_t>(0, int64_t((a - r.start + r.offset) * r.file->rate()));
        const int64_t last = std::min<int64_t>(r.file->frames() - 1, int64_t(std::ceil((b - r.start + r.offset) * r.file->rate())) + 1);
        for (int64_t c = first >> StreamedFile::kChunkShift; c <= (last >> StreamedFile::kChunkShift); ++c) r.file->load(size_t(c));
    }
    std::lock_guard<std::mutex> lock(wake_lock_);
    poke_ = true;
    wake_.notify_all();
}

void DiskStreamer::follow(double seconds, bool playing, bool looping, double loop_from, double loop_to) {
    now_.store(seconds, std::memory_order_relaxed);
    playing_.store(playing, std::memory_order_relaxed);
    looping_.store(looping, std::memory_order_relaxed);
    loop_from_.store(loop_from, std::memory_order_relaxed);
    loop_to_.store(loop_to, std::memory_order_relaxed);
}

void DiskStreamer::settle() {
    const uint64_t from = cycles_.load(std::memory_order_acquire);
    {
        std::lock_guard<std::mutex> lock(wake_lock_);
        poke_ = true;
    }
    wake_.notify_all();
    for (int wait = 0; wait < 2000 && cycles_.load(std::memory_order_acquire) < from + 2; ++wait)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
}

void DiskStreamer::run() {
    std::unique_lock<std::mutex> lock(wake_lock_);
    while (!quit_) {
        poke_ = false;
        lock.unlock();
        cycle();
        cycles_.fetch_add(1, std::memory_order_acq_rel);
        lock.lock();
        wake_.wait_for(lock, std::chrono::milliseconds(20), [this] { return quit_ || poke_; });
    }
}

// What the music needs next (from where it is, a few seconds on, round the loop; or, stopped, where it will start),
// read in soonest first; then, past the budget, what was needed longest ago let go.
void DiskStreamer::cycle() {
    ++cycle_;
    std::vector<StreamRegion> regions;
    double cue_from, cue_to;
    size_t budget;
    {
        std::lock_guard<std::mutex> lock(regions_lock_);
        for (const auto& [track, list] : regions_) regions.insert(regions.end(), list.begin(), list.end());
        cue_from = cue_from_;
        cue_to = cue_to_;
        budget = budget_;
    }
    const double now = now_.load(std::memory_order_relaxed);
    const bool playing = playing_.load(std::memory_order_relaxed);
    const double loop_from = loop_from_.load(std::memory_order_relaxed), loop_to = loop_to_.load(std::memory_order_relaxed);
    struct Span {
        double from, to, lead;  // `lead`: how long until the music gets to `from`
    };
    std::vector<Span> spans;
    if (playing && looping_.load(std::memory_order_relaxed) && loop_to > loop_from && now < loop_to) {
        spans.push_back({now - kBehindSeconds, std::min(now + kAheadSeconds, loop_to), 0.0});
        const double left = kAheadSeconds - (loop_to - now);
        if (left > 0.0) spans.push_back({loop_from, loop_from + std::min(left, loop_to - loop_from), loop_to - now});
    } else {
        spans.push_back({now - kBehindSeconds, now + kAheadSeconds, 0.0});
    }
    if (!playing && cue_to > cue_from) spans.push_back({cue_from, cue_to, 0.0});

    struct Want {
        std::shared_ptr<StreamedFile> file;
        size_t chunk;
        double when;
    };
    std::vector<Want> wants;
    for (const StreamRegion& r : regions) {
        if (!r.file || r.file->rate() <= 0.0) continue;
        Known& known = known_[r.file.get()];
        if (known.file.lock() != r.file) known = {r.file, {}};
        known.needed_at.resize(r.file->chunkCount(), 0);
        for (const Span& span : spans) {
            const double a = std::max(span.from, r.start), b = std::min(span.to, r.start + r.length);
            if (b <= a) continue;
            const double rate = r.file->rate();
            const int64_t first = std::max<int64_t>(0, int64_t((a - r.start + r.offset) * rate));
            const int64_t last = std::min<int64_t>(r.file->frames() - 1, int64_t(std::ceil((b - r.start + r.offset) * rate)) + 1);
            for (int64_t c = first >> StreamedFile::kChunkShift; c <= (last >> StreamedFile::kChunkShift); ++c) {
                const double reached = a + double(std::max<int64_t>(0, (c << StreamedFile::kChunkShift) - first)) / rate;
                wants.push_back({r.file, size_t(c), span.lead + reached - std::max(span.from, now)});
            }
        }
    }
    std::sort(wants.begin(), wants.end(), [](const Want& x, const Want& y) { return x.when < y.when; });
    for (const Want& want : wants) {
        known_[want.file.get()].needed_at[want.chunk] = cycle_;
        want.file->load(want.chunk);
        std::lock_guard<std::mutex> lock(wake_lock_);
        if (quit_) return;
    }

    // What is in memory; past the budget, what was needed longest ago goes.
    size_t bytes = 0;
    std::vector<std::shared_ptr<StreamedFile>> alive;
    struct Spare {
        uint64_t needed_at;
        StreamedFile* file;
        size_t chunk;
    };
    std::vector<Spare> spare;
    for (auto it = known_.begin(); it != known_.end();) {
        auto file = it->second.file.lock();
        if (!file) {  // gone (its chunks with it)
            it = known_.erase(it);
            continue;
        }
        it->second.needed_at.resize(file->chunkCount(), 0);
        for (size_t c = 0; c < file->chunkCount(); ++c) {
            if (!file->loaded(c)) continue;
            bytes += file->chunkBytes();
            if (it->second.needed_at[c] != cycle_) spare.push_back({it->second.needed_at[c], file.get(), c});
        }
        alive.push_back(std::move(file));
        ++it;
    }
    if (bytes > budget) {
        std::sort(spare.begin(), spare.end(), [](const Spare& x, const Spare& y) { return x.needed_at < y.needed_at; });
        for (const Spare& s : spare) {
            if (bytes <= budget) break;
            if (float* memory = s.file->unload(s.chunk)) {  // (the block going now may still be reading it)
                retired_.emplace_back(memory, blocks_.load(std::memory_order_acquire));
                bytes -= s.file->chunkBytes();
            }
        }
    }
    in_memory_.store(bytes, std::memory_order_relaxed);
    freeRetired(false);
}

// Chunks taken out two blocks or more ago: the audio thread, which looks a chunk up afresh each block, can't still be
// reading them.
void DiskStreamer::freeRetired(bool all) {
    const uint64_t block = blocks_.load(std::memory_order_acquire);
    retired_.erase(std::remove_if(retired_.begin(), retired_.end(),
                                  [&](const std::pair<float*, uint64_t>& r) {
                                      if (!all && block < r.second + 2) return false;
                                      delete[] r.first;
                                      return true;
                                  }),
                   retired_.end());
}

}  // namespace sr
