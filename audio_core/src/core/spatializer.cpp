#include "spatializer.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace sr {
namespace {

IPLVector3 ipl(Vec3 v) { return IPLVector3{v.x, v.y, v.z}; }

// Steam Audio's default air absorption coefficients (per metre) for its low / mid / high bands
// (below 800 Hz, 800 Hz–8 kHz, above 8 kHz).
constexpr float kAirAbsorption[3] = {0.0002f, 0.0017f, 0.0182f};

}  // namespace

SteamAudio::~SteamAudio() { release(); }

void SteamAudio::release() {
    if (hrtf_) iplHRTFRelease(&hrtf_);
    if (context_) iplContextRelease(&context_);
    hrtf_ = nullptr;
    context_ = nullptr;
}

bool SteamAudio::init(int sample_rate, int frame_size, std::string* error) {
    release();
    IPLContextSettings cs{};
    cs.version = STEAMAUDIO_VERSION;
    cs.simdLevel = IPL_SIMDLEVEL_AVX2;  // an upper bound; Steam Audio picks NEON on Apple silicon
    if (iplContextCreate(&cs, &context_) != IPL_STATUS_SUCCESS) {
        if (error) *error = "Steam Audio: could not create a context";
        return false;
    }
    settings_.samplingRate = sample_rate;
    settings_.frameSize = frame_size;
    IPLHRTFSettings hs{};
    hs.type = IPL_HRTFTYPE_DEFAULT;
    hs.volume = 1.0f;
    hs.normType = IPL_HRTFNORMTYPE_NONE;
    if (iplHRTFCreate(context_, &settings_, &hs, &hrtf_) != IPL_STATUS_SUCCESS) {
        if (error) *error = "Steam Audio: could not load the default HRTF";
        return false;
    }
    return true;
}

Vec3 SteamAudio::relativeDirection(Vec3 source, Vec3 listener, Vec3 ahead, Vec3 up) const {
    const IPLVector3 d = iplCalculateRelativeDirection(context_, ipl(source), ipl(listener), ipl(ahead), ipl(up));
    if (!std::isfinite(d.x) || !std::isfinite(d.y) || !std::isfinite(d.z)) return Vec3{0, 0, -1};
    return Vec3{d.x, d.y, d.z};
}

SourceSpatializer::~SourceSpatializer() { release(); }

void SourceSpatializer::release() {
    if (binaural_) iplBinauralEffectRelease(&binaural_);
    if (direct_) iplDirectEffectRelease(&direct_);
    binaural_ = nullptr;
    direct_ = nullptr;
}

bool SourceSpatializer::init(const SteamAudio& steam, std::string* error) {
    release();
    steam_ = &steam;
    IPLAudioSettings settings = steam.settings();
    frame_ = settings.frameSize;
    IPLDirectEffectSettings ds{};
    ds.numChannels = 1;
    IPLBinauralEffectSettings bs{};
    bs.hrtf = steam.hrtf();
    if (iplDirectEffectCreate(steam.context(), &settings, &ds, &direct_) != IPL_STATUS_SUCCESS ||
        iplBinauralEffectCreate(steam.context(), &settings, &bs, &binaural_) != IPL_STATUS_SUCCESS) {
        if (error) *error = "Steam Audio: could not create the effects for a source";
        return false;
    }
    in_.assign(size_t(frame_), 0.0f);
    direct_out_.assign(size_t(frame_), 0.0f);
    left_.assign(size_t(frame_), 0.0f);
    right_.assign(size_t(frame_), 0.0f);
    return true;
}

void SourceSpatializer::process(const float* mono, float* out_l, float* out_r, const SpatialParams& p) {
    std::memcpy(in_.data(), mono, sizeof(float) * size_t(frame_));
    float* in_ch[1] = {in_.data()};
    float* direct_ch[1] = {direct_out_.data()};
    IPLAudioBuffer in{1, frame_, in_ch};
    IPLAudioBuffer direct{1, frame_, direct_ch};

    IPLDirectEffectParams dp{};
    dp.flags = IPLDirectEffectFlags(IPL_DIRECTEFFECTFLAGS_APPLYDISTANCEATTENUATION | IPL_DIRECTEFFECTFLAGS_APPLYAIRABSORPTION);
    dp.distanceAttenuation = std::pow(kRefDistance / std::max(kRefDistance, p.distance), p.falloff);
    // Steam Audio applies these three numbers as a three-band EQ, so air and walls share it.
    for (int b = 0; b < 3; ++b)
        dp.airAbsorption[b] = std::exp(-kAirAbsorption[b] * p.distance) * std::clamp(p.band_gain[b], 0.0f, 1.0f);
    iplDirectEffectApply(direct_, &dp, &in, &direct);

    if (p.binaural) {
        if (!was_binaural_) iplBinauralEffectReset(binaural_);
        float* out_ch[2] = {left_.data(), right_.data()};
        IPLAudioBuffer out{2, frame_, out_ch};
        IPLBinauralEffectParams bp{};
        bp.direction = ipl(p.direction);
        bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
        bp.spatialBlend = 1.0f;
        bp.hrtf = steam_->hrtf();
        bp.peakDelays = nullptr;
        iplBinauralEffectApply(binaural_, &bp, &direct, &out);
        for (int i = 0; i < frame_; ++i) {
            out_l[i] += left_[size_t(i)];
            out_r[i] += right_[size_t(i)];
        }
    } else {
        // Equal-power panning on the left/right component of the direction, ramped across the frame.
        const float angle = (std::clamp(p.direction.x, -1.0f, 1.0f) + 1.0f) * 0.25f * 3.14159265f;
        const float target_l = std::cos(angle), target_r = std::sin(angle);
        for (int i = 0; i < frame_; ++i) {
            const float a = float(i + 1) / float(frame_);
            const float gl = pan_l_ + (target_l - pan_l_) * a, gr = pan_r_ + (target_r - pan_r_) * a;
            out_l[i] += direct_out_[size_t(i)] * gl;
            out_r[i] += direct_out_[size_t(i)] * gr;
        }
        pan_l_ = target_l;
        pan_r_ = target_r;
    }
    was_binaural_ = p.binaural;
}

}  // namespace sr
