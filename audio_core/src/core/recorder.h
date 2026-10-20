#pragma once

// Recording audio: what each armed track takes in, handed over by the audio thread a block at a time into a ring of
// its own, and written to a WAV file by a thread of the recorder's own, so the audio thread never waits on the disk.

#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "wav.h"

namespace sr {

class Recorder {
public:
    struct Take {
        int source = -1;
        std::string path;
        int64_t frames = 0;   // as written
        int64_t dropped = 0;  // samples the disk couldn't keep up with (there should be none)
    };

    ~Recorder() { finish(); }
    // Opens a file for each track (game thread) and starts writing: of one channel, or of two for the sources in
    // `stereo` (a stereo mic). False, with the reason, if a file can't be made.
    bool begin(const std::vector<std::pair<int, std::string>>& tracks, int sample_rate, std::string* error,
               const std::vector<int>& stereo = {});
    // Audio thread: `n` samples of what track `slot` (its place in begin's list) takes in; a stereo one's, two at once.
    void write(int slot, const float* x, int n);
    void write(int slot, const float* left, const float* right, int n);
    int slotOf(int source) const;  // its place in the list, or -1
    // Game thread, once the audio thread has stopped writing: what is left is written, and the files closed.
    void finish();
    const std::vector<Take>& takes() const { return takes_; }

private:
    struct Track {
        int source = -1;
        int channels = 1;
        std::vector<float> ring;
        std::atomic<size_t> head{0}, tail{0};
        std::atomic<int64_t> dropped{0};
        WavWriter wav;
    };
    void drain();
    void run();

    std::vector<std::unique_ptr<Track>> tracks_;
    std::vector<Take> takes_;
    std::thread writer_;
    std::atomic<bool> running_{false};
};

}  // namespace sr
