#include "engine.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#include <miniaudio.h>

#ifdef __APPLE__
#include <CoreAudio/CoreAudio.h>
#endif

namespace sr {
namespace {

constexpr float kMasterGain = 1.9f;  // measured: about -21 dBFS RMS at the spawn point, like the prototype
constexpr float kReverbLevel = 0.16f;

Vec3 sub(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
float length(Vec3 v) { return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z); }
Vec3 lerp(Vec3 a, Vec3 b, float t) { return {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t}; }
Vec3 normalized(Vec3 v) {
    const float l = length(v);
    return l > 1e-6f ? Vec3{v.x / l, v.y / l, v.z / l} : Vec3{0, 0, -1};
}

#ifdef __APPLE__
// Frames of latency CoreAudio reports for an output device: device latency + safety offset + stream latency.
double coreAudioDeviceLatencyFrames(AudioObjectID device) {
    auto get = [](AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) -> UInt32 {
        AudioObjectPropertyAddress addr{sel, scope, kAudioObjectPropertyElementMain};
        UInt32 value = 0, size = sizeof(value);
        return AudioObjectGetPropertyData(obj, &addr, 0, nullptr, &size, &value) == noErr ? value : 0;
    };
    double frames = get(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) +
                    get(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput);
    AudioObjectPropertyAddress streams{kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
                                       kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &streams, 0, nullptr, &size) == noErr && size >= sizeof(AudioStreamID)) {
        std::vector<AudioStreamID> ids(size / sizeof(AudioStreamID));
        if (AudioObjectGetPropertyData(device, &streams, 0, nullptr, &size, ids.data()) == noErr)
            frames += get(ids[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal);
    }
    return frames;
}
#endif

}  // namespace

struct AudioEngine::Source {
    int id = 0;
    InstrumentKind kind = InstrumentKind::Keys;
    std::unique_ptr<Instrument> instrument;
    SourceSpatializer spatializer;
    std::vector<float> mono;
    Vec3 pos, target_pos;
    float gain = 1.0f, send = 1.0f;
    float mute_target = 1.0f, mute_gain = 1.0f;
    float visible = 1.0f, visible_target = 1.0f;
};

struct AudioEngine::Device {
    ma_context context{};
    ma_device device{};
    bool context_ok = false, device_ok = false;

    ~Device() {
        if (device_ok) ma_device_uninit(&device);
        if (context_ok) ma_context_uninit(&context);
    }
};

AudioEngine::AudioEngine(const EngineConfig& config)
    : sr_(config.sample_rate), block_(config.block_size), block_pos_(config.block_size) {
    for (auto& l : levels_) l.store(0.0f);
    mix_l_.assign(size_t(block_), 0.0f);
    mix_r_.assign(size_t(block_), 0.0f);
    send_.assign(size_t(block_), 0.0f);
    rev_l_.assign(size_t(block_), 0.0f);
    rev_r_.assign(size_t(block_), 0.0f);
    sequencer_.setSampleRate(sr_);
    reverb_.init(float(sr_), 1.1f, 12.0f);
    limiter_.init(float(sr_));
}

AudioEngine::~AudioEngine() {
    stopDevice();  // the callback must be gone before sources are destroyed
}

int AudioEngine::defaultOutputSampleRate() {
    int rate = 48000;
    ma_context context;
    if (ma_context_init(nullptr, 0, nullptr, &context) != MA_SUCCESS) return rate;
    ma_device_info info;
    if (ma_context_get_device_info(&context, ma_device_type_playback, nullptr, &info) == MA_SUCCESS) {
        for (ma_uint32 i = 0; i < info.nativeDataFormatCount; ++i) {
            const ma_uint32 r = info.nativeDataFormats[i].sampleRate;
            if (r >= 44100 && r <= 96000) {
                rate = int(r);
                break;
            }
        }
    }
    ma_context_uninit(&context);
    return rate;
}

bool AudioEngine::init(std::string* error) {
    if (initialized_) return true;
    initialized_ = steam_.init(sr_, block_, error);
    return initialized_;
}

// ── Device ─────────────────────────────────────────────────────────────────────────────────────────────────
bool AudioEngine::startDevice(DeviceMode mode, std::string* error) {
    if (!initialized_) {
        if (error) *error = "init() has not succeeded";
        return false;
    }
    if (device_) return true;
    auto dev = std::make_unique<Device>();

    ma_context_config cc = ma_context_config_init();
    ma_backend null_backend[] = {ma_backend_null};
    if (ma_context_init(mode == DeviceMode::Null ? null_backend : nullptr, mode == DeviceMode::Null ? 1 : 0, &cc,
                        &dev->context) != MA_SUCCESS) {
        if (error) *error = "could not initialise the audio system";
        return false;
    }
    dev->context_ok = true;

    ma_device_config dc = ma_device_config_init(ma_device_type_playback);
    dc.playback.format = ma_format_f32;
    dc.playback.channels = 2;
    dc.sampleRate = ma_uint32(sr_);
    dc.periodSizeInFrames = ma_uint32(block_);
    dc.performanceProfile = ma_performance_profile_low_latency;
    dc.noPreSilencedOutputBuffer = MA_TRUE;
    dc.noClip = MA_TRUE;
    dc.pUserData = this;
    dc.dataCallback = [](ma_device* d, void* out, const void*, ma_uint32 frames) {
        static_cast<AudioEngine*>(d->pUserData)->render(static_cast<float*>(out), int(frames));
    };
    if (ma_device_init(&dev->context, &dc, &dev->device) != MA_SUCCESS) {
        if (error) *error = "could not open the audio output device";
        return false;
    }
    dev->device_ok = true;

    EngineStats s;
    s.backend = ma_get_backend_name(dev->context.backend);
    s.sample_rate = int(dev->device.playback.internalSampleRate);
    s.block_size = block_;
    s.device_period = int(dev->device.playback.internalPeriodSizeInFrames);
    s.buffer_ms = 1000.0 * s.device_period / s.sample_rate;
#ifdef __APPLE__
    if (dev->context.backend == ma_backend_coreaudio)
        s.device_ms = 1000.0 * coreAudioDeviceLatencyFrames(AudioObjectID(dev->device.coreaudio.deviceObjectIDPlayback)) /
                      s.sample_rate;
#endif
    s.output_latency_ms = s.buffer_ms + s.device_ms;
    s.device_running = true;

    if (ma_device_start(&dev->device) != MA_SUCCESS) {
        if (error) *error = "could not start the audio output device";
        return false;
    }
    device_stats_ = s;
    device_ = std::move(dev);
    return true;
}

void AudioEngine::stopDevice() {
    device_.reset();
    device_stats_.device_running = false;
}

// ── Game-thread API ────────────────────────────────────────────────────────────────────────────────────────
void AudioEngine::push(const Command& c) {
    commands_.push(c);  // if the queue is ever full the command is dropped; positions resend every frame anyway
}

int AudioEngine::addSource(InstrumentKind kind, Vec3 position, float gain, float reverb_send) {
    if (!initialized_ || int(owned_.size()) >= kMaxSources) return -1;
    auto src = std::make_unique<Source>();
    src->id = int(owned_.size());
    src->kind = kind;
    switch (kind) {
        case InstrumentKind::Drums: src->instrument = std::make_unique<Drums>(float(sr_)); break;
        case InstrumentKind::Bass:  src->instrument = std::make_unique<Bass>(float(sr_)); break;
        case InstrumentKind::Pad:   src->instrument = std::make_unique<Pad>(float(sr_)); break;
        case InstrumentKind::Bells: src->instrument = std::make_unique<Bells>(float(sr_)); break;
        case InstrumentKind::Keys:  src->instrument = std::make_unique<Keys>(float(sr_)); break;
    }
    if (!src->spatializer.init(steam_, nullptr)) return -1;
    src->mono.assign(size_t(block_), 0.0f);
    src->pos = src->target_pos = position;
    src->gain = gain;
    src->send = reverb_send;

    Command c;
    c.type = Command::AddSource;
    c.id = src->id;
    c.source = src.get();
    if (!commands_.push(c)) return -1;
    owned_.push_back(std::move(src));
    return c.id;
}

void AudioEngine::setSourcePosition(int id, Vec3 p) {
    Command c; c.type = Command::SourcePosition; c.id = id; c.v[0] = p.x; c.v[1] = p.y; c.v[2] = p.z; push(c);
}
void AudioEngine::setSourceMuted(int id, bool muted) {
    Command c; c.type = Command::SourceMuted; c.id = id; c.v[0] = muted ? 1.0f : 0.0f; push(c);
}
void AudioEngine::setSourceVisibility(int id, float visible) {
    Command c; c.type = Command::SourceVisibility; c.id = id; c.v[0] = visible; push(c);
}
void AudioEngine::setListener(Vec3 p, Vec3 ahead, Vec3 up) {
    Command c; c.type = Command::Listener;
    c.v[0] = p.x; c.v[1] = p.y; c.v[2] = p.z;
    c.v[3] = ahead.x; c.v[4] = ahead.y; c.v[5] = ahead.z;
    c.v[6] = up.x; c.v[7] = up.y; c.v[8] = up.z;
    push(c);
}
void AudioEngine::noteOn(int id, int note, float velocity) {
    Command c; c.type = Command::NoteOn; c.id = id; c.v[0] = float(note); c.v[1] = velocity; push(c);
}
void AudioEngine::noteOff(int id, int note) {
    Command c; c.type = Command::NoteOff; c.id = id; c.v[0] = float(note); push(c);
}
void AudioEngine::allNotesOff(int id) {
    Command c; c.type = Command::AllNotesOff; c.id = id; push(c);
}
void AudioEngine::setBinaural(bool on) {
    Command c; c.type = Command::Binaural; c.v[0] = on ? 1.0f : 0.0f; push(c);
}
void AudioEngine::setReverb(bool on) {
    Command c; c.type = Command::Reverb; c.v[0] = on ? 1.0f : 0.0f; push(c);
}
void AudioEngine::setSequencerRunning(bool on) {
    Command c; c.type = Command::SequencerRunning; c.v[0] = on ? 1.0f : 0.0f; push(c);
}

float AudioEngine::sourceLevel(int id) const {
    return id >= 0 && id < kMaxSources ? levels_[size_t(id)].load(std::memory_order_relaxed) : 0.0f;
}

EngineStats AudioEngine::stats() const {
    EngineStats s = device_stats_;
    if (!s.device_running) {
        s.sample_rate = sr_;
        s.block_size = block_;
    }
    s.cpu_load = cpu_load_.load(std::memory_order_relaxed);
    s.blocks = blocks_.load(std::memory_order_relaxed);
    return s;
}

// ── Audio thread ───────────────────────────────────────────────────────────────────────────────────────────
void AudioEngine::drainCommands() {
    Command c;
    while (commands_.pop(c)) {
        Source* s = (c.id >= 0 && c.id < kMaxSources) ? sources_[size_t(c.id)] : nullptr;
        switch (c.type) {
            case Command::AddSource:
                sources_[size_t(c.id)] = c.source;
                if (!roles_[size_t(c.source->kind)]) roles_[size_t(c.source->kind)] = c.source;
                break;
            case Command::SourcePosition:
                if (s) s->target_pos = {c.v[0], c.v[1], c.v[2]};
                break;
            case Command::SourceMuted:
                if (s) s->mute_target = c.v[0] > 0.5f ? 0.0f : 1.0f;
                break;
            case Command::SourceVisibility:
                if (s) s->visible_target = std::clamp(c.v[0], 0.0f, 1.0f);
                break;
            case Command::Listener:
                target_pos_ = {c.v[0], c.v[1], c.v[2]};
                target_ahead_ = {c.v[3], c.v[4], c.v[5]};
                target_up_ = {c.v[6], c.v[7], c.v[8]};
                break;
            case Command::NoteOn:
                if (s) s->instrument->noteOn(int(c.v[0]), c.v[1]);
                break;
            case Command::NoteOff:
                if (s) s->instrument->noteOff(int(c.v[0]));
                break;
            case Command::AllNotesOff:
                if (s) s->instrument->allNotesOff();
                break;
            case Command::Binaural:
                binaural_ = c.v[0] > 0.5f;
                break;
            case Command::Reverb:
                reverb_target_ = c.v[0] > 0.5f ? 1.0f : 0.0f;
                break;
            case Command::SequencerRunning:
                sequencer_.setRunning(c.v[0] > 0.5f);
                break;
        }
    }
}

int AudioEngine::delayFor(double at) const {
    return std::max(0, int(std::llround(at) - clock_));
}

void AudioEngine::kick(double at, float v) {
    if (Source* s = role(InstrumentKind::Drums)) static_cast<Drums*>(s->instrument.get())->hit(Drums::Kick, v, delayFor(at));
}
void AudioEngine::snare(double at, float v) {
    if (Source* s = role(InstrumentKind::Drums)) static_cast<Drums*>(s->instrument.get())->hit(Drums::Snare, v, delayFor(at));
}
void AudioEngine::hat(double at, float v, bool open) {
    if (Source* s = role(InstrumentKind::Drums))
        static_cast<Drums*>(s->instrument.get())->hit(open ? Drums::HatOpen : Drums::HatClosed, v, delayFor(at));
}
void AudioEngine::bass(double at, int note, float dur_sec, float v) {
    if (Source* s = role(InstrumentKind::Bass)) static_cast<Bass*>(s->instrument.get())->play(note, dur_sec, v, delayFor(at));
}
void AudioEngine::pad(double at, const int* notes, int count, float dur_sec, float v) {
    if (Source* s = role(InstrumentKind::Pad))
        static_cast<Pad*>(s->instrument.get())->play(notes, count, dur_sec, v, delayFor(at));
}
void AudioEngine::bell(double at, int note, float v) {
    if (Source* s = role(InstrumentKind::Bells)) static_cast<Bells*>(s->instrument.get())->play(note, v, delayFor(at));
}

void AudioEngine::render(float* out, int frames) {
    int done = 0;
    while (done < frames) {
        if (block_pos_ >= block_) {
            renderBlock();
            block_pos_ = 0;
        }
        const int n = std::min(frames - done, block_ - block_pos_);
        for (int i = 0; i < n; ++i) {
            out[2 * (done + i)] = mix_l_[size_t(block_pos_ + i)];
            out[2 * (done + i) + 1] = mix_r_[size_t(block_pos_ + i)];
        }
        block_pos_ += n;
        done += n;
    }
}

void AudioEngine::renderBlock() {
    const auto t0 = std::chrono::steady_clock::now();
    drainCommands();

    std::fill(mix_l_.begin(), mix_l_.end(), 0.0f);
    std::fill(mix_r_.begin(), mix_r_.end(), 0.0f);
    std::fill(send_.begin(), send_.end(), 0.0f);
    sequencer_.process(clock_ + block_, *this);

    // Game updates arrive at frame rate; glide toward them so movement doesn't step (time constant ~15 ms).
    const float glide = 1.0f - std::exp(-float(block_) / (0.015f * float(sr_)));
    listener_pos_ = lerp(listener_pos_, target_pos_, glide);
    listener_ahead_ = normalized(lerp(listener_ahead_, target_ahead_, glide));
    listener_up_ = normalized(lerp(listener_up_, target_up_, glide));
    const float wall_glide = 1.0f - std::exp(-float(block_) / (0.06f * float(sr_)));
    const float mute_coef = 1.0f - std::exp(-1.0f / (0.01f * float(sr_)));

    for (Source* s : sources_) {
        if (!s) continue;
        float* mono = s->mono.data();
        std::fill(s->mono.begin(), s->mono.end(), 0.0f);
        s->instrument->render(mono, block_);

        double energy = 0.0;
        for (int i = 0; i < block_; ++i) {
            s->mute_gain += (s->mute_target - s->mute_gain) * mute_coef;
            mono[i] *= s->gain * s->mute_gain;
            energy += double(mono[i]) * mono[i];
            send_[size_t(i)] += mono[i] * s->send;  // the room hears the source even when a wall blocks your view of it
        }
        levels_[size_t(s->id)].store(float(std::sqrt(energy / block_)), std::memory_order_relaxed);

        s->pos = lerp(s->pos, s->target_pos, glide);
        s->visible += (s->visible_target - s->visible) * wall_glide;
        SpatialParams p;
        p.direction = steam_.relativeDirection(s->pos, listener_pos_, listener_ahead_, listener_up_);
        p.distance = length(sub(s->pos, listener_pos_));
        p.visible = s->visible;
        p.binaural = binaural_;
        s->spatializer.process(mono, mix_l_.data(), mix_r_.data(), p);
    }

    reverb_.process(send_.data(), rev_l_.data(), rev_r_.data(), block_);
    const float rev_coef = 1.0f - std::exp(-1.0f / (0.05f * float(sr_)));
    for (int i = 0; i < block_; ++i) {
        reverb_gain_ += (reverb_target_ - reverb_gain_) * rev_coef;
        const float wet = kReverbLevel * reverb_gain_;
        mix_l_[size_t(i)] = (mix_l_[size_t(i)] + rev_l_[size_t(i)] * wet) * kMasterGain;
        mix_r_[size_t(i)] = (mix_r_[size_t(i)] + rev_r_[size_t(i)] * wet) * kMasterGain;
    }
    limiter_.process(mix_l_.data(), mix_r_.data(), block_);
    clock_ += block_;

    const double used = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    const float load = float(used / (double(block_) / sr_));
    cpu_load_.store(cpu_load_.load(std::memory_order_relaxed) * 0.95f + load * 0.05f, std::memory_order_relaxed);
    blocks_.fetch_add(1, std::memory_order_relaxed);
}

}  // namespace sr
