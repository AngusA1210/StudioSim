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
    // How many samples later the binaural rendering comes out than the plain one, measured with a click from straight
    // ahead when it is set up (0 before then). Steam Audio overlaps its frames by a quarter of their length; its
    // Windows HRTF adds a little more than its Mac one does.
    int binauralDelay() const { return binaural_delay_; }

private:
    int measureBinauralDelay() const;

    IPLContext context_ = nullptr;
    IPLHRTF hrtf_ = nullptr;
    IPLAudioSettings settings_{};
    int binaural_delay_ = 0;
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
    static constexpr float kRefDistance = 1.5f;  // full level inside this distance, falling away beyond it
    // Steam Audio's default air absorption coefficients (per metre) for its low / mid / high bands (below 800 Hz,
    // 800 Hz–8 kHz, above 8 kHz).
    static constexpr float kAirAbsorption[3] = {0.0002f, 0.0017f, 0.0182f};
    static constexpr float kBandEdges[2] = {800.0f, 8000.0f};

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
