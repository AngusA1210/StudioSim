#pragma once

// Steam Audio wrappers: one shared context + HRTF, and a per-source chain of
// direct effect (distance, air absorption, frequency-dependent occlusion) → binaural (HRTF) rendering.

#include <string>
#include <vector>

#include <phonon.h>

namespace sr {

struct Vec3 {
    float x = 0, y = 0, z = 0;
};

class SteamAudio {
public:
    ~SteamAudio();
    bool init(int sample_rate, int frame_size, std::string* error);
    IPLContext context() const { return context_; }
    IPLHRTF hrtf() const { return hrtf_; }
    IPLAudioSettings settings() const { return settings_; }
    Vec3 relativeDirection(Vec3 source, Vec3 listener, Vec3 ahead, Vec3 up) const;

private:
    IPLContext context_ = nullptr;
    IPLHRTF hrtf_ = nullptr;
    IPLAudioSettings settings_{};
};

struct SpatialParams {
    Vec3 direction;          // unit vector from listener to source, in listener space (-z ahead, +x right)
    float distance = 1.0f;   // metres
    float visible = 1.0f;    // 1 = clear line of sight, 0 = fully behind a wall
    bool binaural = true;    // false = plain equal-power stereo panning (for A/B comparison)
};

class SourceSpatializer {
public:
    ~SourceSpatializer();
    bool init(const SteamAudio& steam, std::string* error);
    // Renders one frame of mono input and adds the stereo result into out_l / out_r.
    void process(const float* mono, float* out_l, float* out_r, const SpatialParams& params);

    static constexpr float kRefDistance = 1.5f;  // full level inside this distance, 1/d beyond it

private:
    const SteamAudio* steam_ = nullptr;
    IPLDirectEffect direct_ = nullptr;
    IPLBinauralEffect binaural_ = nullptr;
    int frame_ = 0;
    std::vector<float> in_, direct_out_, left_, right_;
    float pan_l_ = 0.7071f, pan_r_ = 0.7071f;
    bool was_binaural_ = true;
};

}  // namespace sr
