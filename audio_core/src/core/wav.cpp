#include "wav.h"

#include <algorithm>
#include <cstring>

namespace sr {
namespace {

void put32(std::FILE* f, uint32_t v) {
    const uint8_t b[4] = {uint8_t(v), uint8_t(v >> 8), uint8_t(v >> 16), uint8_t(v >> 24)};
    std::fwrite(b, 1, 4, f);
}
void put16(std::FILE* f, uint16_t v) {
    const uint8_t b[2] = {uint8_t(v), uint8_t(v >> 8)};
    std::fwrite(b, 1, 2, f);
}
uint32_t get32(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
uint16_t get16(const uint8_t* p) { return uint16_t(p[0] | p[1] << 8); }

}  // namespace

bool WavWriter::open(const std::string& path, int sample_rate, std::string* error) {
    close();
    file_ = std::fopen(path.c_str(), "wb");
    if (!file_) {
        if (error) *error = "it couldn't be made: " + path;
        return false;
    }
    frames_ = 0;
    std::fwrite("RIFF", 1, 4, file_);
    put32(file_, 0);  // filled in on closing
    std::fwrite("WAVEfmt ", 1, 8, file_);
    put32(file_, 16);
    put16(file_, 3);  // IEEE float
    put16(file_, 1);  // one channel
    put32(file_, uint32_t(sample_rate));
    put32(file_, uint32_t(sample_rate) * 4);
    put16(file_, 4);
    put16(file_, 32);
    std::fwrite("data", 1, 4, file_);
    put32(file_, 0);
    return true;
}

void WavWriter::write(const float* samples, size_t count) {
    if (!file_ || count == 0) return;
    std::fwrite(samples, sizeof(float), count, file_);
    frames_ += int64_t(count);
}

void WavWriter::close() {
    if (!file_) return;
    const uint32_t data = uint32_t(frames_ * 4);
    std::fseek(file_, 4, SEEK_SET);
    put32(file_, 36 + data);
    std::fseek(file_, 40, SEEK_SET);
    put32(file_, data);
    std::fclose(file_);
    file_ = nullptr;
}

bool readWav(const std::string& path, AudioData* out, std::string* error) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) {
        if (error) *error = "it couldn't be opened: " + path;
        return false;
    }
    std::vector<uint8_t> bytes;
    uint8_t chunk[65536];
    for (size_t got; (got = std::fread(chunk, 1, sizeof(chunk), f)) > 0;) bytes.insert(bytes.end(), chunk, chunk + got);
    std::fclose(f);
    if (bytes.size() < 12 || std::memcmp(bytes.data(), "RIFF", 4) != 0 || std::memcmp(bytes.data() + 8, "WAVE", 4) != 0) {
        if (error) *error = "it isn't a WAV file";
        return false;
    }
    int format = 0, channels = 0, bits = 0;
    uint32_t rate = 0;
    const uint8_t* data = nullptr;
    size_t data_size = 0;
    for (size_t at = 12; at + 8 <= bytes.size();) {
        const uint32_t size = get32(&bytes[at + 4]);
        const uint8_t* body = &bytes[at + 8];
        const size_t room = bytes.size() - (at + 8);
        if (std::memcmp(&bytes[at], "fmt ", 4) == 0 && size >= 16 && room >= 16) {
            format = get16(body);
            channels = get16(body + 2);
            rate = get32(body + 4);
            bits = get16(body + 14);
            if (format == 0xFFFE && size >= 40 && room >= 40) format = get16(body + 24);  // WAVE_FORMAT_EXTENSIBLE
        } else if (std::memcmp(&bytes[at], "data", 4) == 0) {
            data = body;
            data_size = std::min<size_t>(size, room);
        }
        at += 8 + size + (size & 1);
    }
    const bool float32 = format == 3 && bits == 32, pcm = format == 1 && (bits == 16 || bits == 24 || bits == 32);
    if (!data || channels < 1 || rate == 0 || !(float32 || pcm)) {
        if (error) *error = "its kind of WAV can't be read";
        return false;
    }
    const size_t width = size_t(bits / 8), frames = data_size / (width * size_t(channels));
    out->rate = double(rate);
    out->samples.assign(frames, 0.0f);
    for (size_t i = 0; i < frames; ++i) {
        float sum = 0.0f;
        for (int c = 0; c < channels; ++c) {
            const uint8_t* p = data + (i * size_t(channels) + size_t(c)) * width;
            float v;
            if (float32) std::memcpy(&v, p, 4);
            else if (bits == 16) v = float(int16_t(get16(p))) / 32768.0f;
            else if (bits == 24) v = float(int32_t(uint32_t(p[0]) << 8 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 24) >> 8) / 8388608.0f;
            else v = float(int32_t(get32(p))) / 2147483648.0f;
            sum += v;
        }
        out->samples[i] = sum / float(channels);
    }
    return true;
}

}  // namespace sr
