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
    // Can be called again to change the sample rate or frame size; every SourceSpatializer must then be re-inited.
    bool init(int sample_rate, int frame_size, std::string* error);
    void release();
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
    Vec3 direction;          // unit vector from the listener toward where the sound arrives from, in listener space
    float distance = 1.0f;   // metres travelled, including any detour around a wall
    float falloff = 1.0f;    // how fast the level drops with distance: 1 halves it (-6 dB) per doubling, 0.5 is -3 dB
    float band_gain[3] = {1.0f, 1.0f, 1.0f};  // what walls leave of the lows / mids / highs
    // The share of the sound that is rendered binaurally (HRTF) rather than with plain equal-power stereo panning
    // (for A/B comparison), at the start and at the end of the frame: 1 = all of it, 0 = none. Anything between
    // splits it across the two, which is how one is switched over to the other without a click.
    float binaural_from = 1.0f, binaural_to = 1.0f;
};

class SourceSpatializer {
public:
    ~SourceSpatializer();
    bool init(const SteamAudio& steam, std::string* error);
    void release();
    // Renders one frame of mono input and adds the stereo result into out_l / out_r.
    void process(const float* mono, float* out_l, float* out_r, const SpatialParams& params);
    // How many samples later the binaural rendering comes out than the plain one: Steam Audio overlaps its frames
    // by a quarter of their length. (Measured rather than documented; the offline checks hold it to this.)
    static int binauralDelay(int frame_size) { return frame_size / 4; }

    static constexpr float kRefDistance = 1.5f;  // full level inside this distance, falling away beyond it

private:
    const SteamAudio* steam_ = nullptr;
    IPLDirectEffect direct_ = nullptr;
    IPLBinauralEffect binaural_ = nullptr;
    int frame_ = 0;
    std::vector<float> in_, direct_out_, left_, right_;
    float pan_l_ = 0.7071f, pan_r_ = 0.7071f;
    int binaural_tail_ = 0;  // frames for which the binaural effect still has sound to give after its input stops
};

}  // namespace sr
