#include "desktop_audio.h"

#include <algorithm>
#include <cmath>

#include "interpolation.h"

#if defined(_WIN32)
#include <windows.h>
#include "miniaudio.h"
#endif

namespace sr {

bool DesktopAudio::start(std::string* error, bool capture) {
    stop();
    std::string problem;
    if (capture && !startPlatform(&problem)) {
        if (error) *error = problem;
        return false;
    }
    chunk_.store(0, std::memory_order_relaxed);
    fresh_.store(true, std::memory_order_release);
    running_.store(true, std::memory_order_release);
    return true;
}

void DesktopAudio::stop() {
    running_.store(false, std::memory_order_release);
    stopPlatform();
    held_ms_.store(0.0f, std::memory_order_relaxed);
}

void DesktopAudio::captured(const float* stereo, int frames, double rate) {
    if (frames <= 0 || rate <= 0.0) return;
    rate_.store(rate, std::memory_order_relaxed);
    if (frames > chunk_.load(std::memory_order_relaxed)) chunk_.store(frames, std::memory_order_relaxed);
    const size_t take = std::min(size_t(frames), ring_.room() / 2);  // (whole frames: both sides or neither)
    ring_.write(stereo, take * 2);
}

// What it plays is read from what has come in, between its samples, at the engine's rate: a touch faster while more
// is held than it aims to hold (twice the most that comes in at once, and a block), a touch slower while less (0.2 %
// at most, the difference smoothed over about a second), and silence while it fills up (at first, or having run dry).
bool DesktopAudio::read(float* left, float* right, int n, double engine_rate) {
    std::fill(left, left + n, 0.0f);
    std::fill(right, right + n, 0.0f);
    if (!running_.load(std::memory_order_acquire) || engine_rate <= 0.0) return false;
    if (fresh_.exchange(false, std::memory_order_acq_rel)) {  // (what was left from before goes)
        ring_.reset();
        frac_ = 0.0;
        fill_error_ = 0.0f;
        waiting_ = true;
    }
    const double rate = rate_.load(std::memory_order_relaxed);
    const double step = rate / engine_rate;  // its samples per the engine's
    const size_t hold = std::max(size_t(rate * 0.005), 2 * size_t(chunk_.load(std::memory_order_relaxed))) + size_t(std::ceil(n * step));
    size_t have = ring_.available() / 2;
    if (waiting_) {
        if (have < hold + size_t(Sinc16::kTaps)) {
            held_ms_.store(float(have * 1000.0 / rate), std::memory_order_relaxed);
            return true;
        }
        waiting_ = false;
    }
    if (have > hold * 4 + 4096) {  // (a burst: too much at once to catch up on gently)
        ring_.skip((have - hold) * 2);
        have = hold;
    }
    const float error = std::clamp((float(have) - float(hold)) / float(hold), -1.0f, 1.0f);
    fill_error_ += (error - fill_error_) * std::min(1.0f, float(n / engine_rate));
    const double s = step * (1.0 + 0.002 * double(fill_error_));
    float w[Sinc16::kTaps];
    for (int i = 0; i < n; ++i) {
        if (ring_.available() / 2 < size_t(Sinc16::kTaps + 1)) {
            waiting_ = true;  // run dry: fill up again
            break;
        }
        Sinc16::weights(float(frac_), w);
        float l = 0.0f, r = 0.0f;
        for (int k = 0; k < Sinc16::kTaps; ++k) {
            l += w[k] * ring_.at(size_t(2 * k));
            r += w[k] * ring_.at(size_t(2 * k + 1));
        }
        left[i] = l;
        right[i] = r;
        frac_ += s;
        const double whole = std::floor(frac_);
        if (whole > 0.0) {
            ring_.skip(size_t(whole) * 2);
            frac_ -= whole;
        }
    }
    held_ms_.store(float((ring_.available() / 2) * 1000.0 / rate), std::memory_order_relaxed);
    return true;
}

#if defined(_WIN32)

// Windows: WASAPI's loopback of the default output, leaving StudioSim's own sound out (Windows 10 2004 or later), or
// before then every app's.
struct DesktopAudio::Platform {
    ma_context context{};
    ma_device device{};
    bool context_ready = false;
    bool device_ready = false;
};

namespace {
void onLoopback(ma_device* device, void*, const void* input, ma_uint32 frames) {
    if (input) static_cast<DesktopAudio*>(device->pUserData)->captured(static_cast<const float*>(input), int(frames), double(device->sampleRate));
}
}  // namespace

DesktopAudio::DesktopAudio() { Sinc16::prepare(); }
DesktopAudio::~DesktopAudio() { stop(); }

bool DesktopAudio::startPlatform(std::string* error) {
    auto p = std::make_unique<Platform>();
    ma_backend wasapi[] = {ma_backend_wasapi};
    if (ma_context_init(wasapi, 1, nullptr, &p->context) != MA_SUCCESS) {
        *error = "Windows' audio (WASAPI) couldn't be opened";
        return false;
    }
    p->context_ready = true;
    ma_device_config config = ma_device_config_init(ma_device_type_loopback);
    config.capture.format = ma_format_f32;
    config.capture.channels = 2;
    config.dataCallback = onLoopback;
    config.pUserData = this;
    config.wasapi.loopbackProcessID = GetCurrentProcessId();  // (all but StudioSim)
    config.wasapi.loopbackProcessExclude = MA_TRUE;
    ma_result result = ma_device_init(&p->context, &config, &p->device);
    if (result != MA_SUCCESS) {  // (before Windows 10 2004: every app's sound, StudioSim's too, from the default output)
        config.wasapi.loopbackProcessID = 0;
        config.wasapi.loopbackProcessExclude = MA_FALSE;
        result = ma_device_init(&p->context, &config, &p->device);
    }
    if (result != MA_SUCCESS) {
        ma_context_uninit(&p->context);
        *error = "Windows' sound output couldn't be taken in";
        return false;
    }
    p->device_ready = true;
    if (ma_device_start(&p->device) != MA_SUCCESS) {
        ma_device_uninit(&p->device);
        ma_context_uninit(&p->context);
        *error = "Windows' sound output couldn't be taken in";
        return false;
    }
    platform_ = std::move(p);
    return true;
}

void DesktopAudio::stopPlatform() {
    if (!platform_) return;
    if (platform_->device_ready) ma_device_uninit(&platform_->device);
    if (platform_->context_ready) ma_context_uninit(&platform_->context);
    platform_.reset();
}

#elif !defined(__APPLE__)

// Elsewhere: not yet.
struct DesktopAudio::Platform {};

DesktopAudio::DesktopAudio() { Sinc16::prepare(); }
DesktopAudio::~DesktopAudio() { stop(); }

bool DesktopAudio::startPlatform(std::string* error) {
    *error = "desktop audio is taken in on macOS and Windows";
    return false;
}

void DesktopAudio::stopPlatform() {}

#endif

}  // namespace sr
