#pragma once

// WAV files: writing what is recorded (32-bit float, one channel, as it is), and reading audio back for playback, in
// any of the usual forms (16-, 24- or 32-bit integers, or 32-bit float; any number of channels, mixed down to one).

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace sr {

struct AudioData {
    std::vector<float> samples;  // one channel
    double rate = 48000.0;
    double seconds() const { return rate > 0.0 ? double(samples.size()) / rate : 0.0; }
};

bool readWav(const std::string& path, AudioData* out, std::string* error);

// Writes a mono 32-bit float WAV, its sizes filled in when it is closed.
class WavWriter {
public:
    ~WavWriter() { close(); }
    bool open(const std::string& path, int sample_rate, std::string* error);
    void write(const float* samples, size_t count);
    void close();
    int64_t frames() const { return frames_; }

private:
    std::FILE* file_ = nullptr;
    int64_t frames_ = 0;
};

}  // namespace sr
