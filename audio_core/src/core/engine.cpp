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

// Sound falls 6 dB for each doubling of distance, as the inverse square law has it. The mix was first balanced to be
// heard from about seven metres away, which left it 13 dB hotter right beside an instrument, enough to push the
// output into the limiter. The whole output (the instruments, the reverb and the click alike, so the balance between
// them is unchanged) is therefore 6.7 dB lower than it was, leaving headroom close up. The master volume at +6.7 dB
// gives the old level exactly.
constexpr float kDefaultFalloffDb = 6.0f;
const float kStage = std::sqrt(SourceSpatializer::kRefDistance / 7.0f);
const float kMasterGain = 1.9f * kStage;  // about -28 dBFS RMS at the spawn point, peaks around -12
const float kReverbLevel = 0.16f;
const float kClickLevel = 0.13f;  // the metronome peaks about 10 dB above the mix's average level
// The room the reverb was tuned in. Other sizes are worked out from it, keeping the same wall surfaces.
constexpr float kReferenceRoom[3] = {14.0f, 4.0f, 10.0f};  // width, height, depth in metres
constexpr float kReferenceDecay = 1.1f;                    // its reverb time (RT60) in seconds
constexpr float kPredelayMs = 12.0f;
constexpr float kReverbFadeSeconds = 0.3f;
constexpr float kBinauralFadeSeconds = 0.03f;  // switching binaural on or off crossfades over about this long

float volumeOf(const float r[3]) { return r[0] * r[1] * r[2]; }
float surfaceOf(const float r[3]) { return 2.0f * (r[0] * r[1] + r[1] * r[2] + r[0] * r[2]); }

// The delay lines and pre-delay stretch with the room, within what still sounds like a room rather than echoes.
void buildReverb(FdnReverb& reverb, float sr, float rt60, float size) {
    reverb.init(sr, rt60, kPredelayMs * std::clamp(size, 0.3f, 3.5f), std::clamp(size, 0.5f, 1.8f));
}
constexpr size_t kFifoFrames = 4096;

Vec3 sub(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
float length(Vec3 v) { return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z); }
Vec3 lerp(Vec3 a, Vec3 b, float t) { return {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t}; }
Vec3 normalized(Vec3 v) {
    const float l = length(v);
    return l > 1e-6f ? Vec3{v.x / l, v.y / l, v.z / l} : Vec3{0, 0, -1};
}

// Fills in how many channels the device has.
void describe(ma_context& context, ma_device_type type, const ma_device_id* id, AudioDeviceInfo& out) {
    ma_device_info detail;
    if (ma_context_get_device_info(&context, type, id, &detail) != MA_SUCCESS) return;
    for (ma_uint32 i = 0; i < detail.nativeDataFormatCount; ++i)
        out.channels = std::max(out.channels, int(detail.nativeDataFormats[i].channels));
}

// The sample rate an output device is running at right now. The list of rates a device supports doesn't say
// which one is current, so the reliable way is to open it briefly without asking for a rate.
int currentOutputRate(ma_context& context, const ma_device_id* id) {
    ma_device_config dc = ma_device_config_init(ma_device_type_playback);
    dc.playback.pDeviceID = id;
    dc.playback.format = ma_format_f32;
    dc.dataCallback = [](ma_device*, void*, const void*, ma_uint32) {};
    ma_device probe;
    if (ma_device_init(&context, &dc, &probe) != MA_SUCCESS) return 0;
    const int rate = int(probe.playback.internalSampleRate);
    ma_device_uninit(&probe);
    return rate;
}

std::vector<AudioDeviceInfo> listDevices(ma_device_type type) {
    std::vector<AudioDeviceInfo> out;
    ma_context context;
    if (ma_context_init(nullptr, 0, nullptr, &context) != MA_SUCCESS) return out;
    ma_device_info *playback = nullptr, *capture = nullptr;
    ma_uint32 playback_count = 0, capture_count = 0;
    if (ma_context_get_devices(&context, &playback, &playback_count, &capture, &capture_count) == MA_SUCCESS) {
        const std::vector<ma_device_info> list = type == ma_device_type_playback
            ? std::vector<ma_device_info>(playback, playback + playback_count)
            : std::vector<ma_device_info>(capture, capture + capture_count);
        for (const ma_device_info& info : list) {
            AudioDeviceInfo d;
            d.name = info.name;
            d.is_default = info.isDefault;
            describe(context, type, &info.id, d);
            out.push_back(d);
        }
    }
    ma_context_uninit(&context);
    return out;
}

// Looks a device up by name. Returns false if a name was given and nothing matches.
bool findDevice(ma_context& context, ma_device_type type, const std::string& name, ma_device_id& id, bool& use_default) {
    use_default = name.empty();
    if (use_default) return true;
    ma_device_info *playback = nullptr, *capture = nullptr;
    ma_uint32 playback_count = 0, capture_count = 0;
    if (ma_context_get_devices(&context, &playback, &playback_count, &capture, &capture_count) != MA_SUCCESS) return false;
    const ma_device_info* list = type == ma_device_type_playback ? playback : capture;
    const ma_uint32 count = type == ma_device_type_playback ? playback_count : capture_count;
    for (ma_uint32 i = 0; i < count; ++i) {
        if (name == list[i].name) {
            id = list[i].id;
            return true;
        }
    }
    return false;
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
    float gain = 1.0f, gain_target = 1.0f, send = 1.0f;
    float mute_target = 1.0f, mute_gain = 1.0f;
    int input_channel = LiveInput::kAllInputs;
    // The pattern the sequencer plays on this source. These belong to the audio thread...
    std::array<PatternNote, kMaxPatternNotes> notes;
    int note_count = 0, steps = kMaxPatternSteps;
    bool loop = true;
    // ...and this is the game thread's own copy, to hand back to whoever is editing it.
    std::vector<PatternNote> pattern;
    int pattern_steps = kMaxPatternSteps;
    // Where the game put it, and whether a wall hides it from the listener (game thread).
    Vec3 position;
    bool blocked = false;
    // Leaving the room: the game thread marks it `removing`; the audio thread fades it out over `fade_blocks`,
    // forgets it, and sets `released`, after which the game thread is free to delete it.
    bool removing = false;
    int fade_blocks = -1;
    std::atomic<bool> released{false};
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
    : sr_(config.sample_rate), block_(config.block_size), wanted_rt60_(kReferenceDecay), wanted_level_(kReverbLevel),
      room_rt60_(kReferenceDecay), room_level_(kReverbLevel), falloff_target_(kDefaultFalloffDb / 6.0f),
      falloff_(kDefaultFalloffDb / 6.0f), reverb_level_(kReverbLevel), block_pos_(config.block_size) {
    for (auto& l : levels_) l.store(0.0f);
    allocateBuffers();
    sequencer_.setSampleRate(sr_);
    for (auto& reverb : reverbs_) buildReverb(reverb, float(sr_), room_rt60_, room_size_);
    limiter_.init(float(sr_));
}

AudioEngine::~AudioEngine() {
    midi_.stop();  // no more events into the queue
    stopDevice();  // the callback must be gone before sources are destroyed
}

void AudioEngine::allocateBuffers() {
    for (auto* buf : {&mix_l_, &mix_r_, &send_, &rev_l_, &rev_r_, &rev2_l_, &rev2_r_, &click_}) buf->assign(size_t(block_), 0.0f);
    for (auto& ch : input_bus_.channel) ch.assign(size_t(block_), 0.0f);
    for (auto* delay : {&send_delay_, &click_delay_}) delay->init(SourceSpatializer::binauralDelay(block_));
    input_fifo_.assign(kFifoFrames * InputBus::kMaxChannels, 0.0f);
    input_read_ = input_count_ = 0;
    block_pos_ = block_;  // nothing rendered yet
}

std::unique_ptr<Instrument> AudioEngine::makeInstrument(InstrumentKind kind) const {
    const float sr = float(sr_);
    switch (kind) {
        case InstrumentKind::Drums: return std::make_unique<Drums>(sr);
        case InstrumentKind::Bass:  return std::make_unique<Bass>(sr);
        case InstrumentKind::Pad:   return std::make_unique<Pad>(sr);
        case InstrumentKind::Bells: return std::make_unique<Bells>(sr);
        case InstrumentKind::Keys:  return std::make_unique<Keys>(sr);
        case InstrumentKind::Live:  return std::make_unique<LiveInput>(sr, &input_bus_);
    }
    return nullptr;
}

std::vector<AudioDeviceInfo> AudioEngine::outputDevices() { return listDevices(ma_device_type_playback); }
std::vector<AudioDeviceInfo> AudioEngine::inputDevices() { return listDevices(ma_device_type_capture); }

bool AudioEngine::init(std::string* error) {
    if (initialized_) return true;
    initialized_ = steam_.init(sr_, block_, error);
    return initialized_;
}

bool AudioEngine::configure(int sample_rate, int block_size, std::string* error) {
    if (device_) {
        if (error) *error = "close the audio device before changing its settings";
        return false;
    }
    if (sample_rate == sr_ && block_size == block_) return true;
    const double ratio = double(sample_rate) / sr_;
    sr_ = sample_rate;
    block_ = block_size;
    allocateBuffers();
    clock_ = int64_t(double(clock_) * ratio);
    sequencer_.retime(sr_, clock_);  // keep our place in the music
    for (auto& c : clicks_) c.active = false;
    for (auto& reverb : reverbs_) buildReverb(reverb, float(sr_), room_rt60_, room_size_);
    if (reverb_fade_left_ > 0) {  // a change of room was fading in: it has now simply happened
        reverb_fade_left_ = 0;
        reverb_active_ = reverb_next_;
        reverb_level_ = reverb_next_level_;
        reverb_changing_.store(false, std::memory_order_release);
    }
    limiter_.init(float(sr_));
    if (!initialized_) return true;
    if (!steam_.init(sr_, block_, error)) {
        initialized_ = false;
        return false;
    }
    for (auto& s : owned_) {
        if (!s) continue;
        s->instrument = makeInstrument(s->kind);
        s->instrument->setInputChannel(s->input_channel);
        s->mono.assign(size_t(block_), 0.0f);
        if (!s->spatializer.init(steam_, error)) return false;
    }
    return true;
}

// ── Device ─────────────────────────────────────────────────────────────────────────────────────────────────
bool AudioEngine::openDevice(const DeviceConfig& config, std::string* error) {
    if (!initialized_) {
        if (error) *error = "init() has not succeeded";
        return false;
    }
    stopDevice();
    auto dev = std::make_unique<Device>();
    const bool null_mode = config.mode == DeviceMode::Null;

    ma_context_config cc = ma_context_config_init();
    ma_backend null_backend[] = {ma_backend_null};
    if (ma_context_init(null_mode ? null_backend : nullptr, null_mode ? 1 : 0, &cc, &dev->context) != MA_SUCCESS) {
        if (error) *error = "could not initialise the audio system";
        return false;
    }
    dev->context_ok = true;

    ma_device_id output_id{}, input_id{};
    bool default_output = true, default_input = true;
    if (!null_mode) {
        if (!findDevice(dev->context, ma_device_type_playback, config.output_device, output_id, default_output)) {
            if (error) *error = "output device \"" + config.output_device + "\" is not connected";
            return false;
        }
        if (config.input_enabled &&
            !findDevice(dev->context, ma_device_type_capture, config.input_device, input_id, default_input)) {
            if (error) *error = "input device \"" + config.input_device + "\" is not connected";
            return false;
        }
    }

    // Run at the output device's own sample rate so nothing has to be resampled on the way out.
    const int device_rate = null_mode ? 48000 : currentOutputRate(dev->context, default_output ? nullptr : &output_id);
    if (device_rate <= 0) {
        if (error) *error = "could not open the audio output device";
        return false;
    }
    if (!configure(std::clamp(device_rate, 22050, 192000), std::clamp(config.buffer_size, 16, 4096), error)) return false;

    ma_device_config dc = ma_device_config_init(config.input_enabled ? ma_device_type_duplex : ma_device_type_playback);
    dc.playback.format = ma_format_f32;
    dc.playback.channels = 0;  // every output the device has; the mix goes to the chosen pair
    dc.playback.pDeviceID = default_output ? nullptr : &output_id;
    dc.capture.format = ma_format_f32;
    dc.capture.channels = 0;   // every input the device has
    dc.capture.pDeviceID = default_input ? nullptr : &input_id;
    dc.sampleRate = ma_uint32(sr_);
    dc.periodSizeInFrames = ma_uint32(block_);
    dc.performanceProfile = ma_performance_profile_low_latency;
    dc.noClip = MA_TRUE;
    dc.pUserData = this;
    dc.dataCallback = [](ma_device* d, void* out, const void* in, ma_uint32 frames) {
        const int inputs = d->type == ma_device_type_duplex ? int(d->capture.channels) : 0;
        static_cast<AudioEngine*>(d->pUserData)->renderDevice(static_cast<const float*>(in), inputs, static_cast<float*>(out),
                                                             int(d->playback.channels), int(frames));
    };
    if (ma_device_init(&dev->context, &dc, &dev->device) != MA_SUCCESS) {
        if (error) *error = config.input_enabled ? "could not open the audio input and output" : "could not open the audio output device";
        return false;
    }
    dev->device_ok = true;

    EngineStats s;
    s.backend = ma_get_backend_name(dev->context.backend);
    s.output_device = dev->device.playback.name;
    s.output_channels = int(dev->device.playback.channels);
    s.sample_rate = int(dev->device.playback.internalSampleRate);
    s.block_size = block_;
    s.device_period = int(dev->device.playback.internalPeriodSizeInFrames);
    s.buffer_ms = 1000.0 * s.device_period / s.sample_rate;
    s.live_input = config.input_enabled;
    if (config.input_enabled) {
        s.input_device = dev->device.capture.name;
        s.input_channels = int(dev->device.capture.channels);
        s.input_latency_ms = 1000.0 * dev->device.capture.internalPeriodSizeInFrames / dev->device.capture.internalSampleRate;
    }
#ifdef __APPLE__
    if (dev->context.backend == ma_backend_coreaudio) {
        s.device_ms = 1000.0 * coreAudioDeviceLatencyFrames(AudioObjectID(dev->device.coreaudio.deviceObjectIDPlayback),
                                                             kAudioObjectPropertyScopeOutput) / s.sample_rate;
        if (config.input_enabled)
            s.input_latency_ms += 1000.0 * coreAudioDeviceLatencyFrames(AudioObjectID(dev->device.coreaudio.deviceObjectIDCapture),
                                                                        kAudioObjectPropertyScopeInput) /
                                  dev->device.capture.internalSampleRate;
    }
#endif
    s.device_running = true;

    device_config_ = config;
    device_config_.buffer_size = block_;
    // Keep the mix on outputs the device actually has.
    const int last = std::max(s.output_channels - 1, 0);
    device_config_.output_left = std::clamp(config.output_left, 0, last);
    device_config_.output_right = std::clamp(config.output_right, 0, last);
    setOutputChannels(device_config_.output_left, device_config_.output_right);

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
    if (device_config_.input_enabled == enabled) return true;
    DeviceConfig config = device_config_;
    config.input_enabled = enabled;
    if (openDevice(config, error)) return true;
    config.input_enabled = false;  // keep playing even though the input wouldn't open
    std::string ignored;
    openDevice(config, &ignored);
    return false;
}

void AudioEngine::setOutputChannels(int left, int right) {
    out_left_.store(std::max(left, 0), std::memory_order_relaxed);
    out_right_.store(std::max(right, 0), std::memory_order_relaxed);
    device_config_.output_left = std::max(left, 0);
    device_config_.output_right = std::max(right, 0);
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

void AudioEngine::setMidiTarget(int id) {
    Command c; c.type = Command::MidiTarget; c.id = id; push(c);
}

// ── Game-thread API ────────────────────────────────────────────────────────────────────────────────────────
void AudioEngine::push(const Command& c) {
    commands_.push(c);  // if the queue is ever full the command is dropped; positions resend regularly anyway
}

int AudioEngine::addSource(InstrumentKind kind, Vec3 position, float gain, float reverb_send) {
    if (!initialized_) return -1;
    reap();
    if (sourceCount() >= kMaxSources) return -1;
    size_t slot = 0;  // the lowest id not in use
    while (slot < owned_.size() && owned_[slot]) ++slot;
    if (slot >= size_t(kSourceSlots)) return -1;
    auto src = std::make_unique<Source>();
    src->id = int(slot);
    src->kind = kind;
    src->instrument = makeInstrument(kind);
    if (!src->spatializer.init(steam_, nullptr)) return -1;
    src->mono.assign(size_t(block_), 0.0f);
    src->via = src->via_target = src->position = position;
    src->gain = src->gain_target = gain;
    src->send = reverb_send;

    Command c;
    c.type = Command::AddSource;
    c.id = src->id;
    c.source = src.get();
    if (!commands_.push(c)) return -1;
    if (slot == owned_.size()) owned_.push_back(std::move(src));
    else owned_[slot] = std::move(src);
    updatePath(*owned_[slot]);
    return c.id;
}

bool AudioEngine::removeSource(int id) {
    Source* s = owned(id);
    if (!s) return false;
    Command c; c.type = Command::RemoveSource; c.id = id;
    if (!commands_.push(c)) return false;
    s->removing = true;
    reap();
    return true;
}

int AudioEngine::sourceCount() const {
    int count = 0;
    for (const auto& s : owned_)
        if (s && !s->removing) ++count;
    return count;
}

void AudioEngine::reap() {
    for (auto& s : owned_)
        if (s && s->removing && s->released.load(std::memory_order_acquire)) s.reset();
}

void AudioEngine::setSourcePosition(int id, Vec3 p) {
    Source* s = owned(id);
    if (!s) return;
    s->position = p;
    updatePath(*s);
}

void AudioEngine::setSourceGain(int id, float gain) {
    Command c; c.type = Command::SourceGain; c.id = id; c.v[0] = std::clamp(gain, 0.0f, 100.0f); push(c);
}

bool AudioEngine::sourceBlocked(int id) const {
    const Source* s = owned(id);
    return s && s->blocked;
}

// ── The room (game thread) ─────────────────────────────────────────────────────────────────────────────────
void AudioEngine::updatePath(Source& s) {
    if (geometry_.empty()) {  // no walls: straight from where it stands
        s.blocked = false;
        Command c; c.type = Command::SourcePosition; c.id = s.id;
        c.v[0] = s.position.x; c.v[1] = s.position.y; c.v[2] = s.position.z;
        push(c);
        return;
    }
    const DirectPath path = geometry_.directPath(ear_, s.position);
    s.blocked = path.blocked;
    setSourceDirectPath(s.id, path.via, path.extra, path.differences, path.count, path.blocked);
}

void AudioEngine::updatePaths() {
    for (auto& s : owned_)
        if (s && !s->removing) updatePath(*s);
}

void AudioEngine::setRoom(float width, float height, float depth, const std::vector<Wall>& walls) {
    const float room[3] = {std::clamp(width, 2.0f, 100.0f), std::clamp(height, 2.0f, 50.0f), std::clamp(depth, 2.0f, 100.0f)};
    geometry_.setRoom(room[0], room[2], room[1], walls);
    updatePaths();
    // Sabine: the reverb time grows with volume over surface (the same surfaces as the reference room, so the same
    // share of sound is absorbed at each bounce), and the reverberant level falls as the absorbing surface grows.
    wanted_size_ = (volumeOf(room) / surfaceOf(room)) / (volumeOf(kReferenceRoom) / surfaceOf(kReferenceRoom));
    wanted_rt60_ = std::clamp(kReferenceDecay * wanted_size_, 0.15f, 8.0f);
    wanted_level_ = kReverbLevel * std::sqrt(surfaceOf(kReferenceRoom) / surfaceOf(room));
    roomSettled();
}

bool AudioEngine::roomSettled() {
    const bool fading = reverb_changing_.load(std::memory_order_acquire);
    if (wanted_rt60_ == room_rt60_ && wanted_size_ == room_size_ && wanted_level_ == room_level_) return !fading;
    if (fading) return false;  // the last change has to finish fading in before the next can start

    buildReverb(reverbs_[size_t(reverb_spare_)], float(sr_), wanted_rt60_, wanted_size_);
    reverb_changing_.store(true, std::memory_order_release);
    Command c; c.type = Command::Reverb2; c.id = reverb_spare_; c.v[0] = wanted_level_;
    if (!commands_.push(c)) {
        reverb_changing_.store(false, std::memory_order_release);
        return false;
    }
    room_rt60_ = wanted_rt60_;
    room_size_ = wanted_size_;
    room_level_ = wanted_level_;
    reverb_spare_ = 1 - reverb_spare_;
    return false;  // on its way: settled once it has faded in and nothing newer is wanted
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
void AudioEngine::setSourceInputChannel(int id, int channel) {
    if (Source* s = owned(id)) s->input_channel = channel;  // remembered across reconfigures
    Command c; c.type = Command::SourceInputChannel; c.id = id; c.v[0] = float(channel); push(c);
}
void AudioEngine::setListener(Vec3 p, Vec3 ahead, Vec3 up) {
    Command c; c.type = Command::Listener;
    c.v[0] = p.x; c.v[1] = p.y; c.v[2] = p.z;
    c.v[3] = ahead.x; c.v[4] = ahead.y; c.v[5] = ahead.z;
    c.v[6] = up.x; c.v[7] = up.y; c.v[8] = up.z;
    push(c);
    if (p.x != ear_.x || p.y != ear_.y || p.z != ear_.z) {  // turning on the spot changes no route
        ear_ = p;
        updatePaths();
    }
    roomSettled();  // the game calls this every frame, which makes it the place to let the reverb catch up
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
    binaural_wanted_ = on;
    Command c; c.type = Command::Binaural; c.v[0] = on ? 1.0f : 0.0f; push(c);
}
void AudioEngine::setReverb(bool on) {
    Command c; c.type = Command::Reverb; c.v[0] = on ? 1.0f : 0.0f; push(c);
}
void AudioEngine::setMasterVolume(float gain) {
    Command c; c.type = Command::MasterVolume; c.v[0] = std::clamp(gain, 0.0f, 4.0f); push(c);
}

// ── The sequencer (game thread) ────────────────────────────────────────────────────────────────────────────
AudioEngine::Source* AudioEngine::owned(int id) const {
    Source* s = id >= 0 && id < int(owned_.size()) ? owned_[size_t(id)].get() : nullptr;
    return s && !s->removing ? s : nullptr;
}

void AudioEngine::loadDefaultPattern(int id) {
    if (Source* s = owned(id)) {
        setPatternSteps(id, kMaxPatternSteps);
        setPattern(id, defaultPattern(s->kind));
    }
}

void AudioEngine::setPattern(int id, const std::vector<PatternNote>& notes) {
    Source* s = owned(id);
    if (!s) return;
    s->pattern.clear();
    Command c; c.type = Command::PatternClear; c.id = id; push(c);
    for (const PatternNote& n : notes) setPatternNote(id, n);
}

bool AudioEngine::setPatternNote(int id, const PatternNote& note) {
    Source* s = owned(id);
    if (!s) return false;
    PatternNote n = note;
    n.step = std::clamp(n.step, 0, kMaxPatternSteps - 1);
    n.note = std::clamp(n.note, 0, 127);
    n.length = std::clamp(n.length, 0.05f, float(kMaxPatternSteps));
    n.velocity = std::clamp(n.velocity, 0.0f, 1.0f);
    n.chance = std::clamp(n.chance, 0.0f, 1.0f);
    auto existing = std::find_if(s->pattern.begin(), s->pattern.end(),
                                 [&](const PatternNote& p) { return p.step == n.step && p.note == n.note; });
    if (existing != s->pattern.end()) *existing = n;
    else if (int(s->pattern.size()) >= kMaxPatternNotes) return false;
    else s->pattern.push_back(n);
    Command c; c.type = Command::PatternNoteSet; c.id = id;
    c.v[0] = float(n.step); c.v[1] = float(n.note); c.v[2] = n.length; c.v[3] = n.velocity; c.v[4] = n.chance;
    push(c);
    return true;
}

void AudioEngine::removePatternNote(int id, int step, int note) {
    Source* s = owned(id);
    if (!s) return;
    s->pattern.erase(std::remove_if(s->pattern.begin(), s->pattern.end(),
                                    [&](const PatternNote& p) { return p.step == step && p.note == note; }),
                     s->pattern.end());
    Command c; c.type = Command::PatternNoteRemove; c.id = id; c.v[0] = float(step); c.v[1] = float(note); push(c);
}

void AudioEngine::setPatternSteps(int id, int steps) {
    Source* s = owned(id);
    if (!s) return;
    s->pattern_steps = std::clamp(steps, 1, kMaxPatternSteps);
    Command c; c.type = Command::PatternSteps; c.id = id; c.v[0] = float(s->pattern_steps); push(c);
}

std::vector<PatternNote> AudioEngine::pattern(int id) const {
    const Source* s = owned(id);
    return s ? s->pattern : std::vector<PatternNote>{};
}

int AudioEngine::patternSteps(int id) const {
    const Source* s = owned(id);
    return s ? s->pattern_steps : 0;
}

void AudioEngine::setSourceLoop(int id, bool on) {
    Command c; c.type = Command::SourceLoop; c.id = id; c.v[0] = on ? 1.0f : 0.0f; push(c);
}
void AudioEngine::setDistanceFalloff(float db_per_doubling) {
    Command c; c.type = Command::Falloff; c.v[0] = std::clamp(db_per_doubling, 0.0f, 12.0f) / 6.0f; push(c);
}
void AudioEngine::setLimiter(bool on) {
    Command c; c.type = Command::LimiterOn; c.v[0] = on ? 1.0f : 0.0f; push(c);
}

MeterReading AudioEngine::readMeter() {
    MeterReading m;
    m.peak_l = meter_peak_l_.exchange(0.0f, std::memory_order_relaxed);
    m.peak_r = meter_peak_r_.exchange(0.0f, std::memory_order_relaxed);
    m.rms_l = meter_rms_l_.load(std::memory_order_relaxed);
    m.rms_r = meter_rms_r_.load(std::memory_order_relaxed);
    m.limiter_gain = meter_gain_.exchange(1.0f, std::memory_order_relaxed);
    m.clipped = meter_clipped_.exchange(0, std::memory_order_relaxed);
    return m;
}

void AudioEngine::setSequencerRunning(bool on) {
    transport_.running = on;
    Command c; c.type = Command::SequencerRunning; c.v[0] = on ? 1.0f : 0.0f; push(c);
}
void AudioEngine::setTempo(double bpm) {
    transport_.bpm = std::clamp(bpm, Sequencer::kMinBpm, Sequencer::kMaxBpm);
    Command c; c.type = Command::Tempo; c.v[0] = float(transport_.bpm); push(c);
}
void AudioEngine::setSwing(double amount) {
    transport_.swing = std::clamp(amount, 0.0, 0.6);
    Command c; c.type = Command::Swing; c.v[0] = float(transport_.swing); push(c);
}
void AudioEngine::setClick(bool on) {
    transport_.click = on;
    Command c; c.type = Command::Click; c.v[0] = on ? 1.0f : 0.0f; push(c);
}
void AudioEngine::setClickVolume(float gain) {
    transport_.click_volume = std::clamp(gain, 0.0f, 4.0f);
    Command c; c.type = Command::ClickVolume; c.v[0] = transport_.click_volume; push(c);
}

TransportState AudioEngine::transport() const {
    TransportState t = transport_;
    t.step = step_.load(std::memory_order_relaxed);
    return t;
}

float AudioEngine::sourceLevel(int id) const {
    return id >= 0 && id < kSourceSlots ? levels_[size_t(id)].load(std::memory_order_relaxed) : 0.0f;
}

EngineStats AudioEngine::stats() const {
    EngineStats s = device_stats_;
    if (!s.device_running) {
        s.sample_rate = sr_;
        s.block_size = block_;
    }
    // The binaural rendering's delay is the engine's own, not the device's: it comes and goes with the setting.
    s.binaural_ms = binaural_wanted_ ? 1000.0 * SourceSpatializer::binauralDelay(block_) / sr_ : 0.0;
    s.output_latency_ms = s.buffer_ms + s.device_ms + s.binaural_ms;
    s.cpu_load = cpu_load_.load(std::memory_order_relaxed);
    s.blocks = blocks_.load(std::memory_order_relaxed);
    return s;
}

// ── Audio thread ───────────────────────────────────────────────────────────────────────────────────────────
void AudioEngine::drainCommands() {
    Command c;
    while (commands_.pop(c)) {
        Source* s = (c.id >= 0 && c.id < kSourceSlots) ? sources_[size_t(c.id)] : nullptr;
        switch (c.type) {
            case Command::AddSource:
                sources_[size_t(c.id)] = c.source;
                break;
            case Command::RemoveSource:
                if (s) {  // fade it out first, so it doesn't leave with a click
                    s->mute_target = 0.0f;
                    s->loop = false;
                    s->fade_blocks = int(0.06f * float(sr_) / float(block_)) + 1;
                }
                if (midi_target_ == c.id) midi_target_ = -1;
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
            case Command::SourceInputChannel:
                if (s) s->instrument->setInputChannel(int(c.v[0]));
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
                if (clock_ == 0) binaural_mix_ = binaural_ ? 1.0f : 0.0f;  // set before anything has played: nothing to fade from
                break;
            case Command::Reverb:
                reverb_target_ = c.v[0] > 0.5f ? 1.0f : 0.0f;
                break;
            case Command::MasterVolume:
                master_target_ = c.v[0];
                if (clock_ == 0) master_gain_ = master_target_;  // set before anything has played: nothing to glide from
                break;
            case Command::MidiTarget:
                // Whatever was held on the previous instrument would never get its note-off: let it go now.
                if (c.id != midi_target_ && midi_target_ >= 0 && midi_target_ < kSourceSlots && sources_[size_t(midi_target_)])
                    sources_[size_t(midi_target_)]->instrument->allNotesOff();
                midi_target_ = c.id;
                break;
            case Command::PatternNoteSet:
                if (s) {
                    const PatternNote n{int(c.v[0]), int(c.v[1]), c.v[2], c.v[3], c.v[4]};
                    int at = 0;
                    while (at < s->note_count && (s->notes[size_t(at)].step != n.step || s->notes[size_t(at)].note != n.note)) ++at;
                    if (at < kMaxPatternNotes) {
                        s->notes[size_t(at)] = n;
                        s->note_count = std::max(s->note_count, at + 1);
                    }
                }
                break;
            case Command::PatternNoteRemove:
                if (s) {
                    int kept = 0;  // keeps the remaining notes in order, so they still play in the order they were written
                    for (int i = 0; i < s->note_count; ++i) {
                        const PatternNote& n = s->notes[size_t(i)];
                        if (n.step != int(c.v[0]) || n.note != int(c.v[1])) s->notes[size_t(kept++)] = n;
                    }
                    s->note_count = kept;
                }
                break;
            case Command::PatternClear:
                if (s) s->note_count = 0;
                break;
            case Command::PatternSteps:
                if (s) s->steps = std::clamp(int(c.v[0]), 1, kMaxPatternSteps);
                break;
            case Command::SourceLoop:
                if (s) {
                    s->loop = c.v[0] > 0.5f;
                    if (!s->loop) s->instrument->stopSequenced();
                }
                break;
            case Command::SequencerRunning:
                if (c.v[0] > 0.5f) {
                    if (!sequencer_.running()) sequencer_.start(clock_);
                } else {
                    sequencer_.stop();
                    step_.store(-1, std::memory_order_relaxed);
                    for (Source* each : sources_)
                        if (each) each->instrument->stopSequenced();
                }
                break;
            case Command::Tempo:
                sequencer_.setTempo(c.v[0]);
                break;
            case Command::Swing:
                sequencer_.setSwing(c.v[0]);
                break;
            case Command::Click:
                click_on_ = c.v[0] > 0.5f;
                break;
            case Command::ClickVolume:
                click_volume_ = c.v[0];
                break;
            case Command::SourceGain:
                if (s) s->gain_target = c.v[0];
                break;
            case Command::Falloff:
                falloff_target_ = c.v[0];
                if (clock_ == 0) falloff_ = falloff_target_;  // set before anything has played: nothing to glide from
                break;
            case Command::LimiterOn:
                limiter_on_ = c.v[0] > 0.5f;
                break;
            case Command::Reverb2:  // the spare reverb has been rebuilt for a new room: fade over to it
                reverb_next_ = c.id;
                reverb_next_level_ = c.v[0];
                reverb_fade_len_ = reverb_fade_left_ = std::max(1, int(kReverbFadeSeconds * float(sr_)));
                break;
        }
    }
}

void AudioEngine::drainMidi() {
    MidiEvent e;
    while (midi_queue_.pop(e)) {
        Source* s = (midi_target_ >= 0 && midi_target_ < kSourceSlots) ? sources_[size_t(midi_target_)] : nullptr;
        if (!s) continue;  // nobody is at an instrument
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

void AudioEngine::step(int64_t index, double at, double step_samples) {
    step_.store(index, std::memory_order_relaxed);
    const int delay = delayFor(at);
    const float step_sec = float(step_samples / sr_);
    for (Source* s : sources_) {
        if (!s || !s->loop) continue;
        const int local = int(index % s->steps);
        const float jitter = s->instrument->velocityJitter();
        for (int i = 0; i < s->note_count; ++i) {
            const PatternNote& n = s->notes[size_t(i)];
            if (n.step != local) continue;
            if (n.chance < 1.0f && rng_.uniform() >= n.chance) continue;
            const float velocity = jitter > 0.0f ? n.velocity + rng_.uniform() * jitter : n.velocity;
            s->instrument->play(n.note, n.length * step_sec, velocity, delay);
        }
    }
    if (click_on_ && index % 4 == 0) {  // on the beat; beats are never swung
        voice::ToneHit* free_click = &clicks_[0];
        for (auto& c : clicks_)
            if (!c.active) free_click = &c;
        const float pitch = index % kStepsPerBar == 0 ? 2000.0f : 1000.0f;  // the first beat of the bar is higher
        free_click->start(float(sr_), delay, false, pitch, pitch, 0.01f, kClickLevel * click_volume_, 0.05f);
    }
}

void AudioEngine::renderDevice(const float* input, int input_channels, float* output, int output_channels, int frames) {
    const int left = std::min(out_left_.load(std::memory_order_relaxed), output_channels - 1);
    const int right = std::min(out_right_.load(std::memory_order_relaxed), output_channels - 1);
    if (output_channels == 2 && left == 0 && right == 1) {
        render(input, input_channels, output, frames);
        return;
    }
    // Any other layout: render stereo in chunks, then place it on the chosen outputs and silence the rest.
    float stereo[2 * 256];
    std::memset(output, 0, sizeof(float) * size_t(frames) * size_t(output_channels));
    for (int done = 0; done < frames;) {
        const int n = std::min(frames - done, 256);
        render(input ? input + size_t(done) * size_t(input_channels) : nullptr, input_channels, stereo, n);
        for (int i = 0; i < n; ++i) {
            float* frame = output + size_t(done + i) * size_t(output_channels);
            if (left == right) {
                frame[left] = 0.5f * (stereo[2 * i] + stereo[2 * i + 1]);  // a one-channel device gets a mono fold-down
            } else {
                frame[left] = stereo[2 * i];
                frame[right] = stereo[2 * i + 1];
            }
        }
        done += n;
    }
}

void AudioEngine::render(const float* input, int input_channels, float* out, int frames) {
    const int channels = input ? std::min(input_channels, int(InputBus::kMaxChannels)) : 0;
    if (channels != fifo_channels_) {  // the input layout changed (device reopened): start the queue afresh
        fifo_channels_ = channels;
        input_read_ = input_count_ = 0;
    }
    if (channels > 0) {  // queue what was captured; each rendered block takes its share
        for (int i = 0; i < frames; ++i) {
            const size_t slot = (input_read_ + input_count_) % kFifoFrames;
            for (int c = 0; c < channels; ++c)
                input_fifo_[slot * size_t(channels) + size_t(c)] = input[size_t(i) * size_t(input_channels) + size_t(c)];
            if (input_count_ < kFifoFrames) ++input_count_;
            else input_read_ = (input_read_ + 1) % kFifoFrames;  // full: drop the oldest frame
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

    // This block's share of the captured audio, split into one buffer per hardware input.
    input_bus_.active = fifo_channels_;
    const bool have_input = fifo_channels_ > 0 && input_count_ >= size_t(block_);
    for (int c = 0; c < fifo_channels_; ++c) {
        float* dst = input_bus_.channel[size_t(c)].data();
        for (int i = 0; i < block_; ++i)
            dst[i] = have_input ? input_fifo_[((input_read_ + size_t(i)) % kFifoFrames) * size_t(fifo_channels_) + size_t(c)] : 0.0f;
    }
    if (have_input) {
        input_read_ = (input_read_ + size_t(block_)) % kFifoFrames;
        input_count_ -= size_t(block_);
    }

    std::fill(mix_l_.begin(), mix_l_.end(), 0.0f);
    std::fill(mix_r_.begin(), mix_r_.end(), 0.0f);
    std::fill(send_.begin(), send_.end(), 0.0f);
    std::fill(click_.begin(), click_.end(), 0.0f);
    sequencer_.process(clock_ + block_, *this);
    for (auto& c : clicks_)
        if (c.active) for (int i = 0; i < block_ && c.active; ++i) click_[size_t(i)] += c.next();

    // The binaural rendering comes out a quarter of a block late. The click and the reverb's feed don't pass through
    // it, so while binaural is on they are held back by as much, to stay in step with the direct sound whatever the
    // block size. Switching it on or off moves over from one rendering (and its timing) to the other across a few
    // blocks, with what comes in meanwhile shared between the two.
    const float binaural_from = binaural_mix_;
    const float fade = float(block_) / (kBinauralFadeSeconds * float(sr_));
    binaural_mix_ = binaural_ ? std::min(binaural_mix_ + fade, 1.0f) : std::max(binaural_mix_ - fade, 0.0f);
    click_delay_.process(click_.data(), block_, binaural_from, binaural_mix_);

    // Game updates arrive at frame rate; glide toward them so movement doesn't step (time constant ~15 ms).
    const float glide = 1.0f - std::exp(-float(block_) / (0.015f * float(sr_)));
    listener_pos_ = lerp(listener_pos_, target_pos_, glide);
    listener_ahead_ = normalized(lerp(listener_ahead_, target_ahead_, glide));
    listener_up_ = normalized(lerp(listener_up_, target_up_, glide));
    const float wall_glide = 1.0f - std::exp(-float(block_) / (0.05f * float(sr_)));
    falloff_ += (falloff_target_ - falloff_) * wall_glide;
    const float mute_coef = 1.0f - std::exp(-1.0f / (0.01f * float(sr_)));

    for (size_t index = 0; index < sources_.size(); ++index) {
        Source* s = sources_[index];
        if (!s) continue;
        float* mono = s->mono.data();
        std::fill(s->mono.begin(), s->mono.end(), 0.0f);
        s->instrument->render(mono, block_);

        double energy = 0.0;
        for (int i = 0; i < block_; ++i) {
            s->mute_gain += (s->mute_target - s->mute_gain) * mute_coef;
            s->gain += (s->gain_target - s->gain) * mute_coef;
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
        p.binaural_from = binaural_from;
        p.binaural_to = binaural_mix_;
        p.falloff = falloff_;
        s->spatializer.process(mono, mix_l_.data(), mix_r_.data(), p);

        if (s->fade_blocks >= 0 && --s->fade_blocks < 0) {  // removed and faded out: forget it and hand it back
            sources_[index] = nullptr;
            levels_[index].store(0.0f, std::memory_order_relaxed);
            s->released.store(true, std::memory_order_release);  // must be the last thing this thread does with it
        }
    }

    send_delay_.process(send_.data(), block_, binaural_from, binaural_mix_);
    reverbs_[size_t(reverb_active_)].process(send_.data(), rev_l_.data(), rev_r_.data(), block_);
    float reverb_level = reverb_level_;
    if (reverb_fade_left_ > 0) {  // changing rooms: the old reverb dies away as the new one comes up
        reverbs_[size_t(reverb_next_)].process(send_.data(), rev2_l_.data(), rev2_r_.data(), block_);
        for (int i = 0; i < block_; ++i) {
            const float in = 1.0f - float(std::max(reverb_fade_left_ - i, 0)) / float(reverb_fade_len_);
            const float old_gain = reverb_level_ * (1.0f - in), new_gain = reverb_next_level_ * in;
            rev_l_[size_t(i)] = rev_l_[size_t(i)] * old_gain + rev2_l_[size_t(i)] * new_gain;
            rev_r_[size_t(i)] = rev_r_[size_t(i)] * old_gain + rev2_r_[size_t(i)] * new_gain;
        }
        reverb_level = 1.0f;  // the levels are already in
        reverb_fade_left_ -= block_;
        if (reverb_fade_left_ <= 0) {
            reverb_fade_left_ = 0;
            reverb_active_ = reverb_next_;
            reverb_level_ = reverb_next_level_;
            reverb_changing_.store(false, std::memory_order_release);  // the game thread may now reuse the old one
        }
    }
    const float slow = 1.0f - std::exp(-1.0f / (0.05f * float(sr_)));
    for (int i = 0; i < block_; ++i) {
        reverb_gain_ += (reverb_target_ - reverb_gain_) * slow;
        master_gain_ += (master_target_ - master_gain_) * slow;
        const float wet = reverb_level * reverb_gain_, out = kMasterGain * master_gain_;
        // The click goes straight to both ears: it is for the player, not part of the room.
        mix_l_[size_t(i)] = (mix_l_[size_t(i)] + rev_l_[size_t(i)] * wet + click_[size_t(i)]) * out;
        mix_r_[size_t(i)] = (mix_r_[size_t(i)] + rev_r_[size_t(i)] * wet + click_[size_t(i)]) * out;
    }
    if (limiter_on_) {
        const float lowest = limiter_.process(mix_l_.data(), mix_r_.data(), block_);
        if (lowest < meter_gain_.load(std::memory_order_relaxed)) meter_gain_.store(lowest, std::memory_order_relaxed);
    } else {  // nothing holds the mix back: what goes over full scale is cut off, and the meter says so
        uint32_t clipped = 0;
        for (auto* side : {&mix_l_, &mix_r_})
            for (float& v : *side)
                if (std::fabs(v) > 1.0f) {
                    v = std::copysign(1.0f, v);
                    ++clipped;
                }
        if (clipped) meter_clipped_.fetch_add(clipped, std::memory_order_relaxed);
    }
    // The meter reads what leaves for the sound card.
    float peak_l = 0.0f, peak_r = 0.0f;
    double square_l = 0.0, square_r = 0.0;
    for (int i = 0; i < block_; ++i) {
        peak_l = std::max(peak_l, std::fabs(mix_l_[size_t(i)]));
        peak_r = std::max(peak_r, std::fabs(mix_r_[size_t(i)]));
        square_l += double(mix_l_[size_t(i)]) * mix_l_[size_t(i)];
        square_r += double(mix_r_[size_t(i)]) * mix_r_[size_t(i)];
    }
    if (peak_l > meter_peak_l_.load(std::memory_order_relaxed)) meter_peak_l_.store(peak_l, std::memory_order_relaxed);
    if (peak_r > meter_peak_r_.load(std::memory_order_relaxed)) meter_peak_r_.store(peak_r, std::memory_order_relaxed);
    const float settle = std::exp(-float(block_) / (0.3f * float(sr_)));
    meter_ms_l_ = meter_ms_l_ * settle + float(square_l / block_) * (1.0f - settle);
    meter_ms_r_ = meter_ms_r_ * settle + float(square_r / block_) * (1.0f - settle);
    meter_rms_l_.store(std::sqrt(meter_ms_l_), std::memory_order_relaxed);
    meter_rms_r_.store(std::sqrt(meter_ms_r_), std::memory_order_relaxed);
    clock_ += block_;

    const double used = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    const float load = float(used / (double(block_) / sr_));
    cpu_load_.store(cpu_load_.load(std::memory_order_relaxed) * 0.95f + load * 0.05f, std::memory_order_relaxed);
    blocks_.fetch_add(1, std::memory_order_relaxed);
}

}  // namespace sr
