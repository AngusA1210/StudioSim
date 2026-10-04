#include "engine.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#include <miniaudio.h>

#include "acoustics.h"

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
// Frames of latency CoreAudio reports for a device in one direction: device latency + safety offset + stream latency.
double coreAudioDeviceLatencyFrames(AudioObjectID device, AudioObjectPropertyScope scope) {
    auto get = [](AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope sc) -> UInt32 {
        AudioObjectPropertyAddress addr{sel, sc, kAudioObjectPropertyElementMain};
        UInt32 value = 0, size = sizeof(value);
        return AudioObjectGetPropertyData(obj, &addr, 0, nullptr, &size, &value) == noErr ? value : 0;
    };
    double frames = get(device, kAudioDevicePropertyLatency, scope) + get(device, kAudioDevicePropertySafetyOffset, scope);
    AudioObjectPropertyAddress streams{kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain};
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
    float gain = 1.0f, send = 1.0f;
    float mute_target = 1.0f, mute_gain = 1.0f;
    // The direct path to the listener: where the sound arrives from, how far it still travels beyond that point,
    // and what walls leave of each band. Each has a target the audio thread glides toward.
    Vec3 via, via_target;
    float extra = 0.0f, extra_target = 0.0f;
    float band[3] = {1.0f, 1.0f, 1.0f}, band_target[3] = {1.0f, 1.0f, 1.0f};
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
    input_fifo_.assign(8192, 0.0f);
    input_block_.assign(size_t(block_), 0.0f);
    sequencer_.setSampleRate(sr_);
    reverb_.init(float(sr_), 1.1f, 12.0f);
    limiter_.init(float(sr_));
}

AudioEngine::~AudioEngine() {
    midi_.stop();  // no more events into the queue
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
bool AudioEngine::startDevice(DeviceMode mode, bool with_input, std::string* error) {
    if (!initialized_) {
        if (error) *error = "init() has not succeeded";
        return false;
    }
    if (device_) return true;
    device_mode_ = mode;
    auto dev = std::make_unique<Device>();

    ma_context_config cc = ma_context_config_init();
    ma_backend null_backend[] = {ma_backend_null};
    if (ma_context_init(mode == DeviceMode::Null ? null_backend : nullptr, mode == DeviceMode::Null ? 1 : 0, &cc,
                        &dev->context) != MA_SUCCESS) {
        if (error) *error = "could not initialise the audio system";
        return false;
    }
    dev->context_ok = true;

    ma_device_config dc = ma_device_config_init(with_input ? ma_device_type_duplex : ma_device_type_playback);
    dc.playback.format = ma_format_f32;
    dc.playback.channels = 2;
    dc.capture.format = ma_format_f32;
    dc.capture.channels = 0;  // every input the device has; they are summed below
    dc.sampleRate = ma_uint32(sr_);
    dc.periodSizeInFrames = ma_uint32(block_);
    dc.performanceProfile = ma_performance_profile_low_latency;
    dc.noPreSilencedOutputBuffer = MA_TRUE;
    dc.noClip = MA_TRUE;
    dc.pUserData = this;
    dc.dataCallback = [](ma_device* d, void* out, const void* in, ma_uint32 frames) {
        auto* self = static_cast<AudioEngine*>(d->pUserData);
        const float* input = static_cast<const float*>(in);
        float* output = static_cast<float*>(out);
        const ma_uint32 channels = d->capture.channels;
        if (!input || channels <= 1) {
            self->render(input, output, int(frames));
            return;
        }
        // An interface with several inputs: add them together (not average) so whichever one is in use comes
        // through at full level.
        float mono[512];
        for (ma_uint32 done = 0; done < frames;) {
            const ma_uint32 n = std::min<ma_uint32>(frames - done, 512);
            for (ma_uint32 i = 0; i < n; ++i) {
                float sum = 0.0f;
                for (ma_uint32 c = 0; c < channels; ++c) sum += input[(done + i) * channels + c];
                mono[i] = sum;
            }
            self->render(mono, output + done * 2, int(n));
            done += n;
        }
    };
    if (ma_device_init(&dev->context, &dc, &dev->device) != MA_SUCCESS) {
        if (error) *error = with_input ? "could not open the audio input and output" : "could not open the audio output device";
        return false;
    }
    dev->device_ok = true;

    EngineStats s;
    s.backend = ma_get_backend_name(dev->context.backend);
    s.sample_rate = int(dev->device.playback.internalSampleRate);
    s.block_size = block_;
    s.device_period = int(dev->device.playback.internalPeriodSizeInFrames);
    s.buffer_ms = 1000.0 * s.device_period / s.sample_rate;
    s.live_input = with_input;
    if (with_input) {
        s.input_device = dev->device.capture.name;
        s.input_latency_ms = 1000.0 * dev->device.capture.internalPeriodSizeInFrames / dev->device.capture.internalSampleRate;
    }
#ifdef __APPLE__
    if (dev->context.backend == ma_backend_coreaudio) {
        s.device_ms = 1000.0 * coreAudioDeviceLatencyFrames(AudioObjectID(dev->device.coreaudio.deviceObjectIDPlayback),
                                                             kAudioObjectPropertyScopeOutput) / s.sample_rate;
        if (with_input)
            s.input_latency_ms += 1000.0 * coreAudioDeviceLatencyFrames(AudioObjectID(dev->device.coreaudio.deviceObjectIDCapture),
                                                                        kAudioObjectPropertyScopeInput) /
                                  dev->device.capture.internalSampleRate;
    }
#endif
    s.output_latency_ms = s.buffer_ms + s.device_ms;
    s.device_running = true;

    input_read_ = input_count_ = 0;  // safe: no callback is running yet
    if (ma_device_start(&dev->device) != MA_SUCCESS) {
        if (error) *error = "could not start the audio device";
        return false;
    }
    device_stats_ = s;
    device_ = std::move(dev);
    return true;
}

void AudioEngine::stopDevice() {
    device_.reset();
    device_stats_.device_running = false;
    device_stats_.live_input = false;
}

bool AudioEngine::setLiveInput(bool enabled, std::string* error) {
    if (!device_) {
        if (error) *error = "audio is not running";
        return false;
    }
    if (device_stats_.live_input == enabled) return true;
    stopDevice();
    if (startDevice(device_mode_, enabled, error)) return true;
    std::string ignored;
    startDevice(device_mode_, false, &ignored);  // keep playing even though the input wouldn't open
    return false;
}

// ── MIDI ───────────────────────────────────────────────────────────────────────────────────────────────────
bool AudioEngine::startMidi(std::string* error) {
    return midi_.start(
        [this](const MidiEvent& e) {
            midi_queue_.push(e);
            midi_events_.fetch_add(1, std::memory_order_relaxed);
        },
        error);
}

void AudioEngine::pollMidi() { midi_.rescan(); }

std::vector<std::string> AudioEngine::midiDevices() const { return midi_.deviceNames(); }

void AudioEngine::setMidiTarget(int id) {
    Command c; c.type = Command::MidiTarget; c.id = id; push(c);
}

// ── Game-thread API ────────────────────────────────────────────────────────────────────────────────────────
void AudioEngine::push(const Command& c) {
    commands_.push(c);  // if the queue is ever full the command is dropped; positions resend regularly anyway
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
        case InstrumentKind::Live: {
            auto live = std::make_unique<LiveInput>(float(sr_));
            live->setInput(input_block_.data());
            src->instrument = std::move(live);
            break;
        }
    }
    if (!src->spatializer.init(steam_, nullptr)) return -1;
    src->mono.assign(size_t(block_), 0.0f);
    src->via = src->via_target = position;
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
void AudioEngine::setSourceDirectPath(int id, Vec3 via, float extra_length, const float* path_differences, int count,
                                      bool blocked) {
    Command c; c.type = Command::SourceDirectPath; c.id = id;
    c.v[0] = via.x; c.v[1] = via.y; c.v[2] = via.z;
    c.v[3] = std::max(extra_length, 0.0f);
    directPathGains(path_differences, count, blocked, &c.v[4]);
    push(c);
}
void AudioEngine::setSourceMuted(int id, bool muted) {
    Command c; c.type = Command::SourceMuted; c.id = id; c.v[0] = muted ? 1.0f : 0.0f; push(c);
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
                if (s) {
                    s->via_target = {c.v[0], c.v[1], c.v[2]};
                    s->extra_target = 0.0f;
                    for (float& g : s->band_target) g = 1.0f;
                }
                break;
            case Command::SourceDirectPath:
                if (s) {
                    s->via_target = {c.v[0], c.v[1], c.v[2]};
                    s->extra_target = c.v[3];
                    for (int b = 0; b < 3; ++b) s->band_target[b] = c.v[4 + b];
                }
                break;
            case Command::SourceMuted:
                if (s) s->mute_target = c.v[0] > 0.5f ? 0.0f : 1.0f;
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
            case Command::MidiTarget:
                midi_target_ = c.id;
                break;
        }
    }
}

void AudioEngine::drainMidi() {
    MidiEvent e;
    while (midi_queue_.pop(e)) {
        Source* s = (midi_target_ >= 0 && midi_target_ < kMaxSources) ? sources_[size_t(midi_target_)]
                                                                       : role(InstrumentKind::Keys);
        if (!s) continue;
        switch (e.type) {
            case MidiEvent::NoteOn:  s->instrument->noteOn(e.note, e.velocity); break;
            case MidiEvent::NoteOff: s->instrument->noteOff(e.note); break;
            case MidiEvent::Sustain: s->instrument->sustain(e.note != 0); break;
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

void AudioEngine::render(const float* input, float* out, int frames) {
    if (input) {  // queue what was captured; each rendered block takes its share
        const size_t cap = input_fifo_.size();
        for (int i = 0; i < frames; ++i) {
            input_fifo_[(input_read_ + input_count_) % cap] = input[i];
            if (input_count_ < cap) ++input_count_;
            else input_read_ = (input_read_ + 1) % cap;  // full: drop the oldest sample
        }
    }
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
    drainMidi();

    if (input_count_ >= size_t(block_)) {
        const size_t cap = input_fifo_.size();
        for (int i = 0; i < block_; ++i) input_block_[size_t(i)] = input_fifo_[(input_read_ + size_t(i)) % cap];
        input_read_ = (input_read_ + size_t(block_)) % cap;
        input_count_ -= size_t(block_);
    } else {
        std::fill(input_block_.begin(), input_block_.end(), 0.0f);
    }

    std::fill(mix_l_.begin(), mix_l_.end(), 0.0f);
    std::fill(mix_r_.begin(), mix_r_.end(), 0.0f);
    std::fill(send_.begin(), send_.end(), 0.0f);
    sequencer_.process(clock_ + block_, *this);

    // Game updates arrive at frame rate; glide toward them so movement doesn't step (time constant ~15 ms).
    const float glide = 1.0f - std::exp(-float(block_) / (0.015f * float(sr_)));
    listener_pos_ = lerp(listener_pos_, target_pos_, glide);
    listener_ahead_ = normalized(lerp(listener_ahead_, target_ahead_, glide));
    listener_up_ = normalized(lerp(listener_up_, target_up_, glide));
    const float wall_glide = 1.0f - std::exp(-float(block_) / (0.05f * float(sr_)));
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

        s->via = lerp(s->via, s->via_target, glide);
        s->extra += (s->extra_target - s->extra) * wall_glide;
        SpatialParams p;
        for (int b = 0; b < 3; ++b) {
            s->band[b] += (s->band_target[b] - s->band[b]) * wall_glide;
            p.band_gain[b] = s->band[b];
        }
        p.direction = steam_.relativeDirection(s->via, listener_pos_, listener_ahead_, listener_up_);
        p.distance = length(sub(s->via, listener_pos_)) + s->extra;
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
