#include "spatializer.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace sr {
namespace {

IPLVector3 ipl(Vec3 v) { return IPLVector3{v.x, v.y, v.z}; }

}  // namespace

SteamAudio::~SteamAudio() { release(); }

void SteamAudio::release() {
    if (hrtf_) iplHRTFRelease(&hrtf_);
    if (context_) iplContextRelease(&context_);
    hrtf_ = nullptr;
    context_ = nullptr;
    binaural_delay_ = 0;
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
    binaural_delay_ = measureBinauralDelay();
    return true;
}

// A single sample from straight ahead, through the binaural rendering as a source's goes: where it comes out (where it
// first reaches a quarter of its peak, as an onset is heard) is how late that rendering is.
int SteamAudio::measureBinauralDelay() const {
    IPLBinauralEffectSettings bs{};
    bs.hrtf = hrtf_;
    IPLAudioSettings settings = settings_;
    IPLBinauralEffect effect = nullptr;
    if (iplBinauralEffectCreate(context_, &settings, &bs, &effect) != IPL_STATUS_SUCCESS) return settings_.frameSize / 4;
    const int frame = settings_.frameSize;
    const size_t n = size_t(frame);
    std::vector<float> in(n), left(n), right(n), heard;
    for (int f = 0; f * frame < 4096 + frame; ++f) {
        std::fill(in.begin(), in.end(), 0.0f);
        if (f == 0) in[0] = 1.0f;
        float* in_ch[1] = {in.data()};
        float* out_ch[2] = {left.data(), right.data()};
        IPLAudioBuffer in_buf{1, frame, in_ch}, out_buf{2, frame, out_ch};
        IPLBinauralEffectParams bp{};
        bp.direction = IPLVector3{0.0f, 0.0f, -1.0f};
        bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
        bp.spatialBlend = 1.0f;
        bp.hrtf = hrtf_;
        iplBinauralEffectApply(effect, &bp, &in_buf, &out_buf);
        heard.insert(heard.end(), left.begin(), left.end());
    }
    iplBinauralEffectRelease(&effect);
    float peak = 0.0f;
    for (float v : heard) peak = std::max(peak, std::fabs(v));
    for (size_t i = 0; i < heard.size(); ++i)
        if (peak > 0.0f && std::fabs(heard[i]) > 0.25f * peak) return int(i);
    return frame / 4;
}

Vec3 SteamAudio::relativeDirection(Vec3 source, Vec3 listener, Vec3 ahead, Vec3 up) const {
    const IPLVector3 d = iplCalculateRelativeDirection(context_, ipl(source), ipl(listener), ipl(ahead), ipl(up));
    if (!std::isfinite(d.x) || !std::isfinite(d.y) || !std::isfinite(d.z)) return Vec3{0, 0, -1};
    return Vec3{d.x, d.y, d.z};
}

std::array<float, 9> ambisonicGains(Vec3 d) {
    const float n = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    if (n < 1e-6f) return {0.282095f, 0, 0, 0, 0, 0, 0, 0, 0};
    // Steam Audio's listener space (right, up, back) as the harmonics' axes (ahead, left, up).
    const float x = -d.z / n, y = -d.x / n, z = d.y / n;
    return {0.282095f, 0.488603f * y, 0.488603f * z, 0.488603f * x, 1.092548f * x * y, 1.092548f * y * z,
            0.315392f * (3.0f * z * z - 1.0f), 1.092548f * x * z, 0.546274f * (x * x - y * y)};
}

ReflectionField::~ReflectionField() { release(); }

void ReflectionField::release() {
    if (binaural_) iplAmbisonicsDecodeEffectRelease(&binaural_);
    if (panning_) iplAmbisonicsDecodeEffectRelease(&panning_);
    binaural_ = panning_ = nullptr;
}

void ReflectionField::decode(IPLAmbisonicsDecodeEffect effect, bool binaural, float* l, float* r) {
    float* in[kChannels];
    for (int c = 0; c < kChannels; ++c) in[c] = field_[size_t(c)].data();
    float* out[2] = {l, r};
    IPLAudioBuffer in_buf{kChannels, frame_, in}, out_buf{2, frame_, out};
    IPLAmbisonicsDecodeEffectParams p{};
    p.order = 2;
    p.hrtf = steam_->hrtf();
    p.orientation.right = IPLVector3{1.0f, 0.0f, 0.0f};  // (the field is already the listener's way round)
    p.orientation.up = IPLVector3{0.0f, 1.0f, 0.0f};
    p.orientation.ahead = IPLVector3{0.0f, 0.0f, -1.0f};
    p.binaural = binaural ? IPL_TRUE : IPL_FALSE;
    iplAmbisonicsDecodeEffectApply(effect, &p, &in_buf, &out_buf);
}

bool ReflectionField::init(const SteamAudio& steam, std::string* error) {
    release();
    steam_ = &steam;
    IPLAudioSettings settings = steam.settings();
    frame_ = settings.frameSize;
    IPLAmbisonicsDecodeEffectSettings ds{};
    ds.speakerLayout.type = IPL_SPEAKERLAYOUTTYPE_STEREO;
    ds.hrtf = steam.hrtf();
    ds.maxOrder = 2;
    if (iplAmbisonicsDecodeEffectCreate(steam.context(), &settings, &ds, &binaural_) != IPL_STATUS_SUCCESS ||
        iplAmbisonicsDecodeEffectCreate(steam.context(), &settings, &ds, &panning_) != IPL_STATUS_SUCCESS) {
        if (error) *error = "Steam Audio: could not create the reflections' renderers";
        return false;
    }
    for (auto& channel : field_) channel.assign(size_t(frame_), 0.0f);
    for (auto* side : {&bl_, &br_, &pl_, &pr_}) side->assign(size_t(frame_), 0.0f);
    // A click from a few ways round, through the field and through a source's own rendering: how much later the field's
    // binaural rendering is (from straight ahead, where an onset is plainest), and how loud each rendering is against a
    // source's own (its binaural; plain panning, equal power).
    IPLBinauralEffectSettings bs{};
    bs.hrtf = steam.hrtf();
    IPLBinauralEffect direct = nullptr;
    if (iplBinauralEffectCreate(steam.context(), &settings, &bs, &direct) != IPL_STATUS_SUCCESS) return true;  // (as it is)
    const Vec3 ways[] = {{0, 0, -1}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 1, 0}, {0.6f, 0.0f, -0.8f}};
    double field_energy = 0.0, own_energy = 0.0, panned_energy = 0.0;
    const size_t frame = size_t(frame_);
    std::vector<float> in(frame), l(frame), r(frame);
    for (const Vec3& way : ways) {
        iplBinauralEffectReset(direct);
        iplAmbisonicsDecodeEffectReset(binaural_);
        iplAmbisonicsDecodeEffectReset(panning_);
        const std::array<float, 9> gains = ambisonicGains(way);
        std::vector<float> heard_field, heard_own;
        for (int f = 0; f * frame_ < 8192 + frame_; ++f) {
            clear();
            std::fill(in.begin(), in.end(), 0.0f);
            if (f == 0) {
                in[0] = 1.0f;
                for (int c = 0; c < kChannels; ++c) field_[size_t(c)][0] = gains[size_t(c)];
            }
            decode(binaural_, true, l.data(), r.data());
            for (int i = 0; i < frame_; ++i) {
                field_energy += double(l[size_t(i)]) * l[size_t(i)] + double(r[size_t(i)]) * r[size_t(i)];
                heard_field.push_back(l[size_t(i)]);
            }
            decode(panning_, false, l.data(), r.data());
            for (int i = 0; i < frame_; ++i) panned_energy += double(l[size_t(i)]) * l[size_t(i)] + double(r[size_t(i)]) * r[size_t(i)];
            float* in_ch[1] = {in.data()};
            float* out_ch[2] = {l.data(), r.data()};
            IPLAudioBuffer in_buf{1, frame_, in_ch}, out_buf{2, frame_, out_ch};
            IPLBinauralEffectParams bp{};
            bp.direction = IPLVector3{way.x, way.y, way.z};
            bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
            bp.spatialBlend = 1.0f;
            bp.hrtf = steam.hrtf();
            iplBinauralEffectApply(direct, &bp, &in_buf, &out_buf);
            for (int i = 0; i < frame_; ++i) {
                own_energy += double(l[size_t(i)]) * l[size_t(i)] + double(r[size_t(i)]) * r[size_t(i)];
                heard_own.push_back(l[size_t(i)]);
            }
        }
        if (&way == &ways[0]) {  // straight ahead: where each first reaches a quarter of its peak
            const auto onset = [](const std::vector<float>& x) {
                float peak = 0.0f;
                for (float v : x) peak = std::max(peak, std::fabs(v));
                for (size_t i = 0; i < x.size(); ++i)
                    if (peak > 0.0f && std::fabs(x[i]) > 0.25f * peak) return int(i);
                return 0;
            };
            late_ = onset(heard_field) - onset(heard_own);
        }
    }
    iplBinauralEffectRelease(&direct);
    const double count = double(sizeof(ways) / sizeof(ways[0]));  // (plain panning: each way's energy 1)
    binaural_gain_ = field_energy > 0.0 ? float(std::sqrt(own_energy / field_energy)) : 1.0f;
    panning_gain_ = panned_energy > 0.0 ? float(std::sqrt(count / panned_energy)) : 1.0f;
    iplAmbisonicsDecodeEffectReset(binaural_);
    iplAmbisonicsDecodeEffectReset(panning_);
    clear();
    return true;
}

void ReflectionField::clear() {
    for (auto& channel : field_) std::fill(channel.begin(), channel.end(), 0.0f);
    added_ = false;
}

void ReflectionField::add(const float* mono, Vec3 from, Vec3 to, float focus) {
    added_ = true;
    std::array<float, 9> a = ambisonicGains(from), b = ambisonicGains(to);
    for (int c = 1; c < kChannels; ++c) {  // (spread: the first order's channels down by `focus`, the second's by its square)
        const float keep = c < 4 ? focus : focus * focus;
        a[size_t(c)] *= keep;
        b[size_t(c)] *= keep;
    }
    for (int c = 0; c < kChannels; ++c) {
        float* channel = field_[size_t(c)].data();
        const float step = (b[size_t(c)] - a[size_t(c)]) / float(frame_);
        for (int i = 0; i < frame_; ++i) channel[i] += mono[i] * (a[size_t(c)] + step * float(i + 1));
    }
}

void ReflectionField::render(float* out_l, float* out_r, float binaural_from, float binaural_to) {
    if (!binaural_ || !panning_) return;
    quiet_ = added_ ? 0 : quiet_ + 1;
    if (quiet_ > 2 + 8192 / std::max(frame_, 1)) return;  // nothing in it for long enough that nothing is left to come out
    // Both renderings run all the time, so that either is ready to be heard the moment binaural is switched.
    decode(binaural_, true, bl_.data(), br_.data());
    decode(panning_, false, pl_.data(), pr_.data());
    for (int i = 0; i < frame_; ++i) {
        const float share = binaural_from + (binaural_to - binaural_from) * float(i + 1) / float(frame_);
        out_l[i] += bl_[size_t(i)] * binaural_gain_ * share + pl_[size_t(i)] * panning_gain_ * (1.0f - share);
        out_r[i] += br_[size_t(i)] * binaural_gain_ * share + pr_[size_t(i)] * panning_gain_ * (1.0f - share);
    }
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
    binaural_tail_ = 0;
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
        dp.airAbsorption[b] = std::exp(-SourceSpatializer::kAirAbsorption[b] * p.distance) * std::clamp(p.band_gain[b], 0.0f, 1.0f);
    iplDirectEffectApply(direct_, &dp, &in, &direct);

    // What goes into each rendering is its share of the sound, so nothing starts or stops abruptly in either.
    const float from = std::clamp(p.binaural_from, 0.0f, 1.0f), to = std::clamp(p.binaural_to, 0.0f, 1.0f);
    const bool feeding = from > 0.0f || to > 0.0f;
    if (feeding || binaural_tail_ > 0) {
        IPLAudioBuffer* feed = &direct;
        if (from < 1.0f || to < 1.0f) {
            for (int i = 0; i < frame_; ++i)
                in_[size_t(i)] = direct_out_[size_t(i)] * (from + (to - from) * float(i + 1) / float(frame_));
            feed = &in;
        }
        if (binaural_tail_ == 0) iplBinauralEffectReset(binaural_);  // starting afresh
        float* out_ch[2] = {left_.data(), right_.data()};
        IPLAudioBuffer out{2, frame_, out_ch};
        IPLBinauralEffectParams bp{};
        bp.direction = ipl(p.direction);
        bp.interpolation = IPL_HRTFINTERPOLATION_BILINEAR;
        bp.spatialBlend = 1.0f;
        bp.hrtf = steam_->hrtf();
        bp.peakDelays = nullptr;
        iplBinauralEffectApply(binaural_, &bp, feed, &out);
        // It gives out what it takes in a little late, so once its share is nothing it is still run, on silence,
        // until the last of the sound has come out.
        binaural_tail_ = feeding ? std::max(1, (iplBinauralEffectGetTailSize(binaural_) + frame_ - 1) / frame_) : binaural_tail_ - 1;
        for (int i = 0; i < frame_; ++i) {
            out_l[i] += left_[size_t(i)];
            out_r[i] += right_[size_t(i)];
        }
    }
    if (from < 1.0f || to < 1.0f) {
        // Equal-power panning on the left/right component of the direction, ramped across the frame.
        const float angle = (std::clamp(p.direction.x, -1.0f, 1.0f) + 1.0f) * 0.25f * 3.14159265f;
        const float target_l = std::cos(angle), target_r = std::sin(angle);
        if (from >= 1.0f) {  // it has been idle: there is no earlier position to ramp from
            pan_l_ = target_l;
            pan_r_ = target_r;
        }
        for (int i = 0; i < frame_; ++i) {
            const float a = float(i + 1) / float(frame_);
            const float share = 1.0f - (from + (to - from) * a);
            const float gl = pan_l_ + (target_l - pan_l_) * a, gr = pan_r_ + (target_r - pan_r_) * a;
            out_l[i] += direct_out_[size_t(i)] * gl * share;
            out_r[i] += direct_out_[size_t(i)] * gr * share;
        }
        pan_l_ = target_l;
        pan_r_ = target_r;
    }
}

}  // namespace sr
