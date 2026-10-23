#include "engine.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#include <miniaudio.h>

#include "acoustics.h"
#include "interpolation.h"

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
// About -28 dBFS RMS at the spawn point from the instruments alone, peaks around -12; with the room's reflections, as
// the game has them, about -23 dBFS and -6 (the room adds its own, the lows most, as they come back in step).
const float kMasterGain = 1.9f * kStage;
const float kReverbLevel = 0.16f;
const float kClickLevel = 0.13f;  // the metronome peaks about 10 dB above the mix's average level
// The room the reverb was tuned in, with its surfaces as a room starts (materials.h: RoomSurfaces): its reverb is
// kReverbLevel loud, and other rooms' are louder or quieter as they absorb less or more.
constexpr float kReferenceRoom[3] = {14.0f, 4.0f, 10.0f};  // width, height, depth in metres
RoomAcoustics referenceAcoustics() { return roomAcoustics(kReferenceRoom[0], kReferenceRoom[1], kReferenceRoom[2], RoomSurfaces{}); }
constexpr float kPredelayMs = 12.0f;
constexpr float kReverbFadeSeconds = 0.3f;
constexpr float kBinauralFadeSeconds = 0.03f;  // switching binaural on or off crossfades over about this long

float volumeOf(const float r[3]) { return r[0] * r[1] * r[2]; }
float surfaceOf(const float r[3]) { return 2.0f * (r[0] * r[1] + r[1] * r[2] + r[0] * r[2]); }

// The delay lines and pre-delay stretch with the room, within what still sounds like a room rather than echoes.
void buildReverb(FdnReverb& reverb, float sr, const std::array<float, 3>& rt60, float size) {
    reverb.init(sr, rt60, kPredelayMs * std::clamp(size, 0.3f, 3.5f), std::clamp(size, 0.5f, 1.8f));
}
constexpr size_t kFifoFrames = 4096;

Vec3 sub(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
float length(Vec3 v) { return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z); }
float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(Vec3 a, Vec3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
// A point's image beyond a surface (across `axis`, 0 to 2 for x to z, at `plane`), as a mirror shows it.
Vec3 mirror(Vec3 p, int axis, float plane) {
    float& v = axis == 0 ? p.x : (axis == 1 ? p.y : p.z);
    v = 2.0f * plane - v;
    return p;
}
// Where the straight way from `from` to an image beyond a surface strikes the surface.
Vec3 strikeOn(Vec3 from, Vec3 image, int axis, float plane) {
    const auto along = [&](Vec3 p) { return axis == 0 ? p.x : (axis == 1 ? p.y : p.z); };
    const float span = along(image) - along(from);
    const float t = std::fabs(span) > 1e-6f ? std::clamp((plane - along(from)) / span, 0.0f, 1.0f) : 0.5f;
    return {from.x + (image.x - from.x) * t, from.y + (image.y - from.y) * t, from.z + (image.z - from.z) * t};
}
// A direction turned `share` of the way round towards another (round any way at all, if they are opposite).
Vec3 turnToward(Vec3 from, Vec3 to, float share) {
    const float d = std::clamp(dot(from, to), -1.0f, 1.0f);
    if (d > 0.999999f) return to;
    Vec3 axis = cross(from, to);
    if (length(axis) < 1e-6f) axis = cross(from, std::fabs(from.y) < 0.9f ? Vec3{0.0f, 1.0f, 0.0f} : Vec3{1.0f, 0.0f, 0.0f});
    const float l = length(axis);
    axis = {axis.x / l, axis.y / l, axis.z / l};
    const float angle = std::acos(d) * share, c = std::cos(angle), s = std::sin(angle);
    const Vec3 across = cross(axis, from);
    const float along = dot(axis, from) * (1.0f - c);
    return {from.x * c + across.x * s + axis.x * along, from.y * c + across.y * s + axis.y * along, from.z * c + across.z * s + axis.z * along};
}
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
    std::vector<float> bus_l, bus_r;  // a bus: what its tracks play into it this block
    int output = -1;                  // where it plays (the audio thread's): a bus's id, or -1 for the master
    float gain = 1.0f, gain_target = 1.0f, send = 1.0f;
    float volume = 1.0f, volume_target = 1.0f;  // its own volume, before the fader (setSourceVolume)
    float mute_target = 1.0f, mute_gain = 1.0f;
    int input_channel = LiveInput::kAllInputs;
    bool input_on = false;  // see setSourceInput; kept by both threads (the game's copy survives a reconfigure)
    // Amps: the knobs (the game thread's copy, put back if the amp is rebuilt).
    std::array<float, kAmpControls> amp_controls{5, 5, 5, 5, 5, 5};
    AmpHead amp_head = AmpHead::Crunch;
    AmpCabinet amp_cabinet = AmpCabinet::OpenBack1x12;
    AmpSpeaker amp_speaker = AmpSpeaker::AmericanVintage;
    float loop_mix = 0.5f;  // its effects loop's Mix
    int loop_delay = 0;     // how late its loop's plug-ins make what comes back (its preamp's own signal is held back as much)
    bool head_on = true, cabinet_on = true;
    // An amp's effect pedals, the loop pedal among them if it has one. They live here rather than in the amp, so that
    // a loop survives a change of buffer size. The game thread owns them, in order, with what it last set on each; the audio thread
    // plays through `board`, its own copy of the order, which a PedalBoardSet command replaces. Each order sent has
    // a number; a pedal taken off the board waits in `retired` until the audio thread has applied an order without it.
    struct PedalSlot {
        std::unique_ptr<Pedal> pedal;
        bool on = true;
        PedalControls controls{};
    };
    std::vector<PedalSlot> pedals;
    int fx_loop = 0;  // how many of them, at the end, are in the effects loop
    // Any source's inserts: one plug-in, or none, in each slot. The audio thread plays through `insert_board`, the
    // ones there are in slot order. Both boards' orders are numbered from the same count.
    std::array<PedalSlot, kMaxInserts> inserts;
    PedalBoard insert_board;
    // A plug-in instrument's plug-in, held as a Plug-in pedal holds one, and handed to its PluginSynth the same way.
    PedalSlot synth;
    // Its clips on the timeline (a Record room): the game thread's, and the copy the audio thread plays, replaced as
    // pedal boards are (and the old one freed once the audio thread has let go of it).
    struct Track {
        std::vector<TimelineNote> notes;  // in order of their steps
        struct Clip {
            double start = 0.0, offset = 0.0, length = 0.0, fade_in = 0.0, fade_out = 0.0;
            float gain = 1.0f;
            std::shared_ptr<StreamedFile> file;  // read from disk as it plays (see disk_stream.h)
        };
        std::vector<Clip> clips;
        TrackAutomation automation;
    };
    std::unique_ptr<Track> track;
    bool read_volume = true, read_mute = true, read_sustain = true, read_params = true;  // its automation read (the audio thread's)
    struct Send {
        int bus = -1;
        float gain = 0.0f, gain_target = 0.0f;
        bool pre = false, on = true;
    };
    std::array<Send, AudioEngine::kMaxSends> sends;  // the audio thread's
    // Its first reflections, as the listener hears them: off each of the room's surfaces (faces()), from its image beyond
    // it; what the game thread worked out (where the image is, what of each band it sends back as a mirror and what it
    // scatters, a loudspeaker's beaming as heard from the image), then the audio thread's glides and filters' state.
    struct Echo {
        Vec3 image{}, source{};
        float gain = 0.0f, gain_target = 0.0f, cut = 20000.0f, cut_target = 20000.0f;
        bool filtered = false;
        std::array<float, 3> mirror{}, mirror_target{}, scatter{}, scatter_target{};
        float late = -1.0f;            // samples behind the direct sound (-1: not heard yet)
        Vec3 way{0.0f, 0.0f, -1.0f};   // the way it arrives from, last block
        float air_at = -1.0f, air[3] = {};  // what the air leaves of each band, over the distance it was last worked out for
        int bus = 0;                   // the surface whose scattered sound it adds to
        bool second = false;           // off two surfaces (put in the field at first order: it needs less precision)
    };
    std::array<Echo, AudioEngine::kEchoes> echoes;
    std::array<bool, AudioEngine::kEchoes> echo_sent{};  // (the game thread's: which it last told the audio thread of)
    // Delay compensation: the game thread's copy of where it plays and where its sends go, what it has worked out (its
    // plug-ins' delay, how far its output and each send are held back), and the delay lines that hold them back (made
    // when first needed, and kept while it is); then the audio thread's hold of them, its output's first.
    int route = -1;
    std::array<int, AudioEngine::kMaxSends> send_to{-1, -1, -1, -1, -1};
    AudioEngine::TrackDelay delay;
    std::array<int, AudioEngine::kMaxSends> send_compensation{};
    std::array<std::unique_ptr<CompensationDelay>, 1 + AudioEngine::kMaxSends> holds;
    std::array<CompensationDelay*, 1 + AudioEngine::kMaxSends> holds_rt{};
    std::array<int, 1 + AudioEngine::kMaxSends> held_by{};
    std::vector<float> pre, out_l, out_r;  // a block of its sound before its fader, and placed in the room (for sends; a bus
                                           // keeps what reaches its fader in out_l and out_r)
    float auto_mute = 1.0f;     // its mute automation's share of it heard, glided
    float solo_target = 1.0f, solo_gain = 1.0f;  // silenced by a solo elsewhere: out of the mix, still in the room
    // A source in the room: its level there (how loud it sounds where it stands, made up of its normal level and the room
    // fader), and its room mute, both glided; and this block of its sound there, to be placed for the listener.
    float room_gain = 1.0f, room_gain_target = 1.0f;
    float room_mute = 1.0f, room_mute_target = 1.0f;
    std::vector<float> room;
    // A loudspeaker cabinet (an amp's): its cones, where the game put them (the game thread's: radiation.h). The listener
    // hears it through a low-pass and a level for where they stand against its baffle (glided), and the room's reverb
    // hears its power response, duller than on its axis (a one-pole's corner; 0 for none): the audio thread's, as is the
    // cones' radius, for how flat their waves are close up.
    Radiator radiator;
    bool facing_sent = false;  // (the game thread's: the listener's side told it has cones)
    float facing_cut = 20000.0f, facing_cut_target = 20000.0f, facing_gain = 1.0f, facing_gain_target = 1.0f;
    bool facing = false;
    EqFilter facing_lp;
    float power_cut = 0.0f, power_state = 0.0f, cone_radius = 0.0f;
    int master_role = 0;  // a bus carrying a master's inserts (1 + its Monitor), not played as a bus (the audio thread's)
    // A source in the room: its sound there (after its fader and mute), the last kHistory samples, for microphones to
    // hear as late as it reaches them.
    static constexpr size_t kHistory = size_t(1) << 16;  // 1.4 s at 48 kHz: 470 m of air
    std::vector<float> history;
    // And split as Steam Audio's bands are (below 800 Hz; below 8 kHz), as it was written, so that a reflection is
    // read already split: its three bands are the low, below_high - low, and history - below_high.
    std::vector<float> history_low, history_below_high;
    float split_low = 0.0f, split_below_high = 0.0f;
    // A microphone: each source as it hears it (the audio thread's). Its distance along the way it comes (straight, or
    // round a wall), what the walls leave of each band, all glided as they move; and its band split's state.
    struct Pickup {
        float distance = -1.0f, target = -1.0f;  // -1: not heard (no way worked out yet)
        float band[3] = {1.0f, 1.0f, 1.0f}, band_target[3] = {1.0f, 1.0f, 1.0f};
        Vec3 from{0.0f, 0.0f, 1.0f}, from_target{0.0f, 0.0f, 1.0f};  // the way it arrives from (towards where it bends round)
        float low = 0.0f, below_high = 0.0f;
        float near_in = 0.0f, near_out = 0.0f;  // the proximity effect's filter
        // A loudspeaker cabinet is heard by its cones (and its open back), each its own way (radiation.h): how long,
        // how near, its level, its filters (the beaming and the place on the cone, the near field's lows, the dust
        // cap's bite), the way it arrives from, all glided; each with its own filters' and band split's state. The
        // walls' dulling is the source's (band). None: heard as a point, as above.
        struct Way {
            bool filtered = true;  // (a point's direct way has no filters)
            bool reflection = false;  // off a surface other than the floor: read already split, without filters (see hearCapsule)
            float air_at = -1.0f, air[3] = {};  // (a reflection's: what the air leaves of each band, over the distance last worked out)
            float distance = -1.0f, distance_target = 0.0f, nearness = 1.0f, nearness_target = 1.0f;
            float gain = 0.0f, gain_target = 0.0f, cut = 20000.0f, cut_target = 20000.0f;
            float low_db = 0.0f, low_target = 0.0f, high_db = 0.0f, high_target = 0.0f;
            float bands[3] = {1.0f, 1.0f, 1.0f}, bands_target[3] = {1.0f, 1.0f, 1.0f};  // what a surface it comes off leaves
            float scatter[3] = {}, scatter_target[3] = {};  // and scatters (heard spread out, from all over it)
            int surface = -1;                               // whose scattered sound it adds to (kScatterBuses), if anyone's
            Vec3 from{0.0f, 0.0f, 1.0f}, from_target{0.0f, 0.0f, 1.0f};
            float low = 0.0f, below_high = 0.0f, near_in = 0.0f, near_out = 0.0f;
            std::array<EqFilter, 3> filters{};
        };
        int ways = 0;
        std::array<Way, kMaxWays> way;
    };
    // A microphone's model, as the audio thread plays it: its pattern band by band, what of the reverb it hears band by
    // band, its response on axis, its sensitivity, its noise (its own and its preamp's, as a white noise's amplitude).
    struct MicSound {
        MicPolar polar;
        float diffuse[3] = {1.0f, 1.0f, 1.0f};
        std::array<EqFilter, 8> eq{};
        int eq_count = 0;
        float sensitivity = 1.0f;
        float noise = 0.0f;
        float rev_low = 0.0f, rev_below_high = 0.0f;
        bool gradient = false;  // some of it hears the pressure gradient (and so has a proximity effect)
        int model = 0, pattern = 0;  // (made again for a new sample rate)
    };
    // A microphone's capsule: where it hears from (the game thread's; a mono mic's is where it stands, a stereo mic's
    // either side of that), what kind it is, which way it points (glided), and each source as it hears it.
    struct Capsule {
        Vec3 position;
        MicSound sound;
        Vec3 aim{0.0f, 0.0f, 1.0f}, aim_target{0.0f, 0.0f, 1.0f};
        std::unique_ptr<std::array<Pickup, AudioEngine::kSourceSlots>> pickups;
        Rng hiss;
        // What each of the room's surfaces scatters to it this block (already as its pattern hears a diffuse sound), to
        // be spread out in time.
        std::array<std::vector<float>, AudioEngine::kScatterBuses> scatter;
        std::array<Smear, AudioEngine::kScatterBuses> smear;
        std::array<int, AudioEngine::kScatterBuses> quiet{};  // blocks since each was last fed
    };
    std::array<Capsule, 2> capsules;
    int capsule_count = 0;  // a microphone's one, a stereo mic's two (left and right, or mid and side)
    bool mid_side = false;  // a stereo mic's capsules are mid and side, decoded to left and right
    float width = 1.0f, width_target = 1.0f;  // (how much of the side, decoding)
    std::vector<float> mono_r, pre_r, playback_r;  // a stereo mic's second channel
    float pan = 0.0f, pan_target = 0.0f;  // a microphone's track: where it sits in the stereo (a stereo one's, its balance)
    bool bus_mono = false;  // a folder's bus summed to mono, its pan placing it; else stereo, its pan a balance
    bool hear_input = false;  // a microphone, this block: what it hears (rather than its clips) is its track's sound
    bool auto_sustain = false;  // the sustain pedal down by automation
    Track* track_rt = nullptr;
    std::vector<std::pair<std::unique_ptr<Track>, uint32_t>> retired_tracks;
    bool armed = false;            // armed for recording (the audio thread's copy)
    std::vector<float> playback;   // this block's recorded audio, played into it
    std::vector<std::pair<std::unique_ptr<Pedal>, uint32_t>> retired;
    uint32_t board_sent = 0;
    std::atomic<uint32_t> board_applied{0};
    PedalBoard board;
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
    : sr_(config.sample_rate), block_(config.block_size), wanted_rt60_(referenceAcoustics().decay), wanted_level_(kReverbLevel),
      room_rt60_(referenceAcoustics().decay), room_level_(kReverbLevel), falloff_target_(kDefaultFalloffDb / 6.0f),
      falloff_(kDefaultFalloffDb / 6.0f), reverb_level_(kReverbLevel), block_pos_(config.block_size) {
    for (auto& l : levels_) l.store(0.0f);
    for (auto* meters : {&peaks_, &pre_levels_, &pre_peaks_})
        for (auto& p : *meters) p.store(0.0f);
    Sinc16::prepare();  // (its table, before the audio thread wants it)
    allocateBuffers();
    sequencer_.setSampleRate(sr_);
    for (auto& reverb : reverbs_) buildReverb(reverb, float(sr_), room_rt60_, room_size_);
    limiter_.init(float(sr_));
    room_limiter_.init(float(sr_));
}

AudioEngine::~AudioEngine() {
    midi_.stop();  // no more events into the queue
    stopDevice();  // the callback must be gone before sources are destroyed
}

void AudioEngine::allocateBuffers() {
    for (auto* buf : {&mix_l_, &mix_r_, &send_, &rev_l_, &rev_r_, &rev2_l_, &rev2_r_, &click_, &room_l_, &room_r_, &out_l_, &out_r_,
                      &mix_tap_l_, &mix_tap_r_, &room_tap_l_, &room_tap_r_, &comp_l_, &comp_r_, &echo_, &read_})
        buf->assign(size_t(block_), 0.0f);
    for (auto& bus : echo_scatter_) bus.assign(size_t(block_), 0.0f);
    for (auto& smear : echo_smear_) smear.init(float(sr_));
    split_lows_ = 1.0f - std::exp(-2.0f * float(kPi) * SourceSpatializer::kBandEdges[0] / float(sr_));
    split_highs_ = 1.0f - std::exp(-2.0f * float(kPi) * SourceSpatializer::kBandEdges[1] / float(sr_));
    for (auto& ch : input_bus_.channel) ch.assign(size_t(block_), 0.0f);
    block_seconds_.assign(size_t(block_), -1.0);
    take_.assign(size_t(block_), 0.0f);
    for (auto* delay : {&send_delay_, &click_delay_}) delay->init(steam_.binauralDelay());
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
        case InstrumentKind::GarageDrums: return std::make_unique<GarageKit>(sr);
        case InstrumentKind::StudioDrums: return std::make_unique<StudioKit>(sr);
        case InstrumentKind::PluginSynth: return std::make_unique<PluginSynth>(sr);
        case InstrumentKind::Live:  return std::make_unique<LiveInput>(sr, &input_bus_);
        case InstrumentKind::GuitarCombo:
        case InstrumentKind::GuitarStack:
        case InstrumentKind::BassCombo:
        case InstrumentKind::BassStack:
            return std::make_unique<Amp>(sr, kind, &input_bus_, block_);
        case InstrumentKind::Bus:
        case InstrumentKind::Mic:  // (what it plays is what it hears: see hearCapsule)
        case InstrumentKind::StereoMic:
            return std::make_unique<Silence>(sr);
    }
    return nullptr;
}

void AudioEngine::connect(Source& s) {
    s.playback.assign(size_t(block_), 0.0f);
    s.instrument->setPlayback(isLiveInput(s.kind) ? s.playback.data() : nullptr);
    if (s.kind == InstrumentKind::PluginSynth) {
        auto* holder = static_cast<PluginPedal*>(s.synth.pedal.get());
        static_cast<PluginSynth*>(s.instrument.get())->setPlugin(holder && holder->ready() ? holder->plugin() : nullptr);
    }
    if (!isAmp(s.kind)) return;
    auto* amp = static_cast<Amp*>(s.instrument.get());
    amp->connect(&s.board, bar_timing_);
    amp->setHead(s.amp_head, s.head_on);
    amp->setCabinet(s.amp_cabinet, s.cabinet_on);
    amp->setSpeaker(s.amp_speaker);
    amp->setLoopMix(s.loop_mix);
    amp->setLoopDelay(s.loop_delay);
    for (int c = 0; c < kAmpControls; ++c) amp->setControl(AmpControl(c), s.amp_controls[size_t(c)]);
}

std::vector<AudioDeviceInfo> AudioEngine::outputDevices() { return listDevices(ma_device_type_playback); }
std::vector<AudioDeviceInfo> AudioEngine::inputDevices() { return listDevices(ma_device_type_capture); }

bool AudioEngine::init(std::string* error) {
    if (initialized_) return true;
    initialized_ = steam_.init(sr_, block_, error) && reflections_.init(steam_, error);
    for (auto* delay : {&send_delay_, &click_delay_}) delay->init(steam_.binauralDelay());  // (now that it is known)
    return initialized_;
}

bool AudioEngine::configure(int sample_rate, int block_size, std::string* error) {
    if (device_) {
        if (error) *error = "close the audio device before changing its settings";
        return false;
    }
    if (sample_rate == sr_ && block_size == block_) return true;
    // The audio thread is stopped: apply whatever it hasn't yet, so that nothing waiting in the queue refers to memory
    // freed below.
    drainCommands();
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
    room_limiter_.init(float(sr_));
    if (!initialized_) return true;
    if (!steam_.init(sr_, block_, error) || !reflections_.init(steam_, error)) {
        initialized_ = false;
        return false;
    }
    for (auto* delay : {&send_delay_, &click_delay_}) delay->init(steam_.binauralDelay());
    for (auto& s : owned_) {
        if (!s) continue;
        s->instrument = makeInstrument(s->kind);
        s->instrument->setInputChannel(s->input_channel);
        s->instrument->setInputEnabled(s->input_on);
        connect(*s);
        if (ratio != 1.0) {  // made ready for the new rate (a loop pedal's loop is lost: it would play at the wrong speed)
            for (auto& slot : s->pedals) slot.pedal->prepare(float(sr_));
            for (auto& slot : s->inserts)
                if (slot.pedal) slot.pedal->prepare(float(sr_));
            if (s->synth.pedal) {
                s->synth.pedal->prepare(float(sr_));
                connect(*s);
            }
        }
        s->mono.assign(size_t(block_), 0.0f);
        s->bus_l.assign(size_t(block_), 0.0f);
        s->bus_r.assign(size_t(block_), 0.0f);
        for (auto* buffer : {&s->pre, &s->out_l, &s->out_r}) buffer->assign(size_t(block_), 0.0f);
        for (int k = 0; k < s->capsule_count; ++k) {  // (its filters at the new rate; what it hears scattered, a block of)
            soundAs(*s, k, s->capsules[size_t(k)].sound.model, s->capsules[size_t(k)].sound.pattern);
            for (auto& bus : s->capsules[size_t(k)].scatter) bus.assign(size_t(block_), 0.0f);
            for (auto& smear : s->capsules[size_t(k)].smear) smear.init(float(sr_));
        }
        for (auto* buffer : {&s->mono_r, &s->pre_r, &s->playback_r, &s->room})
            if (!buffer->empty()) buffer->assign(size_t(block_), 0.0f);
        if (!s->spatializer.init(steam_, error)) return false;
    }
    updateDelayCompensation();  // (the plug-ins' delays, in samples at the new rate)
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

    realtime_.store(true, std::memory_order_release);
    if (ma_device_start(&dev->device) != MA_SUCCESS) {
        realtime_.store(false, std::memory_order_release);
        if (error) *error = "could not start the audio device";
        return false;
    }
    device_stats_ = s;
    device_ = std::move(dev);
    return true;
}

void AudioEngine::stopDevice() {
    device_.reset();
    realtime_.store(false, std::memory_order_release);
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

void AudioEngine::receiveMidi(const MidiEvent& e) { midi_queue_.push(e); }

void AudioEngine::setAmpControl(int id, AmpControl control, float value) {
    Source* s = owned(id);
    if (!s || !isAmp(s->kind)) return;
    s->amp_controls[size_t(control)] = std::clamp(value, 0.0f, 10.0f);
    Command c; c.type = Command::AmpKnob; c.id = id; c.v[0] = float(int(control)); c.v[1] = s->amp_controls[size_t(control)]; push(c);
}

LooperPedal* AudioEngine::looperOf(const Source& s) const {
    for (const auto& slot : s.pedals)
        if (slot.pedal->kind() == PedalKind::Looper) return static_cast<LooperPedal*>(slot.pedal.get());
    return nullptr;
}

void AudioEngine::setAmpHead(int id, AmpHead head, bool on) {
    Source* s = owned(id);
    if (!s || !isAmp(s->kind)) return;
    s->amp_head = head;
    s->head_on = on;
    Command c; c.type = Command::AmpHeadSet; c.id = id; c.v[0] = float(int(head)); c.v[1] = on ? 1.0f : 0.0f; push(c);
}

void AudioEngine::setAmpCabinet(int id, AmpCabinet cabinet, bool on) {
    Source* s = owned(id);
    if (!s || !isAmp(s->kind)) return;
    s->amp_cabinet = cabinet;
    s->cabinet_on = on;
    Command c; c.type = Command::AmpCabinetSet; c.id = id; c.v[0] = float(int(cabinet)); c.v[1] = on ? 1.0f : 0.0f; push(c);
    if (speakerInfo(s->amp_speaker).inches != cabinetInches(cabinet)) setAmpSpeaker(id, defaultSpeaker(cabinet));
}

void AudioEngine::setAmpSpeaker(int id, AmpSpeaker speaker) {
    Source* s = owned(id);
    if (!s || !isAmp(s->kind) || speakerInfo(speaker).inches != cabinetInches(s->amp_cabinet)) return;
    s->amp_speaker = speaker;
    Command c; c.type = Command::AmpSpeakerSet; c.id = id; c.v[0] = float(int(speaker)); push(c);
    const SpeakerInfo info = speakerInfo(speaker);  // its cones as the room hears them
    s->radiator.breakup_hz = info.breakup_hz;
    s->radiator.cap_db = info.cap_db;
    updateMicPaths(*s);
}

AmpSpeaker AudioEngine::ampSpeaker(int id) const {
    const Source* s = owned(id);
    return s ? s->amp_speaker : AmpSpeaker::AmericanVintage;
}

void AudioEngine::setAmpLoopMix(int id, float mix) {
    Source* s = owned(id);
    if (!s || !isAmp(s->kind)) return;
    s->loop_mix = std::clamp(mix, 0.0f, 1.0f);
    Command c; c.type = Command::AmpLoopMix; c.id = id; c.v[0] = s->loop_mix; push(c);
}

float AudioEngine::ampLoopMix(int id) const {
    const Source* s = owned(id);
    return s ? s->loop_mix : 0.5f;
}

bool AudioEngine::looperAction(int id, Looper::Action action) {
    Source* s = owned(id);
    LooperPedal* pedal = s ? looperOf(*s) : nullptr;
    if (!pedal) return false;
    if (action == Looper::Press && pedal->allocate(kLoopSeconds)) {  // its first recording: give it somewhere to record
        Command m; m.type = Command::LooperMemory; m.id = id; m.pedals[0] = pedal;
        m.memory[0] = pedal->memory(0);
        m.memory[1] = pedal->memory(1);
        m.count = pedal->capacity();
        push(m);
    }
    Command c; c.type = Command::LooperAct; c.id = id; c.pedals[0] = pedal; c.v[0] = float(int(action)); push(c);
    return true;
}

LooperStatus AudioEngine::looperStatus(int id) const {
    LooperStatus out;
    const Source* s = owned(id);
    const LooperPedal* pedal = s ? looperOf(*s) : nullptr;
    if (!pedal) return out;
    const Looper& looper = pedal->looper();
    out.present = true;
    out.state = looper.state();
    out.length = double(looper.length()) / sr_;
    out.position = double(looper.position()) / sr_;
    out.capacity = kLoopSeconds;
    out.can_undo = looper.canUndo();
    out.can_redo = looper.canRedo();
    return out;
}

// ── Pedals (game thread) ───────────────────────────────────────────────────────────────────────────────────
bool AudioEngine::sendBoard(Source& s, bool inserts) {
    Command c; c.type = Command::PedalBoardSet; c.id = s.id; c.v[0] = inserts ? 1.0f : 0.0f;
    if (inserts) {
        for (size_t i = 0; i < s.inserts.size(); ++i)
            if (s.inserts[i].pedal) {
                c.slots[c.count] = int8_t(i);
                c.pedals[c.count++] = s.inserts[i].pedal.get();
            }
    } else {
        for (const auto& slot : s.pedals) c.pedals[c.count++] = slot.pedal.get();
        s.fx_loop = std::clamp(s.fx_loop, 0, int(s.pedals.size()));
        c.v[1] = float(int(s.pedals.size()) - s.fx_loop);
    }
    c.epoch = s.board_sent + 1;
    if (!commands_.push(c)) return false;
    s.board_sent = c.epoch;
    updateDelayCompensation();  // (its plug-ins may have come or gone)
    return true;
}

void AudioEngine::reapPedals() {
    for (size_t m = 0; m < 2; ++m) {
        const uint32_t master_applied = master_applied_[m].load(std::memory_order_acquire);
        auto& retired = retired_master_[m];
        retired.erase(std::remove_if(retired.begin(), retired.end(), [&](const auto& r) { return r.second <= master_applied; }), retired.end());
    }
    for (auto& s : owned_) {
        if (!s || (s->retired.empty() && s->retired_tracks.empty())) continue;
        const uint32_t applied = s->board_applied.load(std::memory_order_acquire);
        s->retired.erase(std::remove_if(s->retired.begin(), s->retired.end(), [&](const auto& r) { return r.second <= applied; }),
                         s->retired.end());
        s->retired_tracks.erase(std::remove_if(s->retired_tracks.begin(), s->retired_tracks.end(),
                                               [&](const auto& r) { return r.second <= applied; }),
                                s->retired_tracks.end());
    }
}

// ── The timeline and recording (game thread) ───────────────────────────────────────────────────────────────
void AudioEngine::playFrom(double step) {
    const uint32_t cue = streamer_.prepare(std::max(step, 0.0) * 15.0 / transport_.bpm);  // (the first moments read in before it starts)
    Command c; c.type = Command::TimelinePlay; c.v[0] = float(std::max(step, 0.0)); c.epoch = cue; push(c);
    transport_.running = true;
}

void AudioEngine::setLoopRange(bool on, double start_step, double end_step) {
    Command c; c.type = Command::TimelineLoop; c.v[0] = on ? 1.0f : 0.0f; c.v[1] = float(start_step); c.v[2] = float(end_step); push(c);
}

std::shared_ptr<StreamedFile> AudioEngine::audioFile(const std::string& path, std::string* error) {
    for (auto it = audio_files_.begin(); it != audio_files_.end(); ++it)
        if (it->first == path) {
            if (it->second->unchanged()) return it->second;
            audio_files_.erase(it);  // written again since: opened afresh (clips playing the old one keep it till they go)
            break;
        }
    auto file = StreamedFile::open(path, error);
    if (!file) return nullptr;
    audio_files_.emplace_back(path, file);
    return file;
}

bool AudioEngine::setTrack(int id, const std::vector<TimelineNote>& notes, const std::vector<ClipSpec>& clips, std::string* error,
                           const TrackAutomation& automation) {
    reapPedals();
    Source* s = owned(id);
    if (!s) {
        if (error) *error = "there is no such track";
        return false;
    }
    auto track = std::make_unique<Source::Track>();
    track->notes = notes;
    track->automation = automation;
    for (auto* lane : {&track->automation.volume, &track->automation.mute, &track->automation.sustain})
        std::stable_sort(lane->begin(), lane->end(), [](const AutoPoint& a, const AutoPoint& b) { return a.step < b.step; });
    std::sort(track->notes.begin(), track->notes.end(), [](const TimelineNote& a, const TimelineNote& b) { return a.step < b.step; });
    bool all = true;
    for (const ClipSpec& spec : clips) {
        std::string why;
        auto audio = audioFile(spec.path, &why);
        if (!audio) {
            if (error && all) *error = why;
            all = false;
            continue;
        }
        const double fade_in = std::clamp(spec.fade_in, 0.0, spec.length), fade_out = std::clamp(spec.fade_out, 0.0, spec.length - fade_in);
        track->clips.push_back({spec.start, spec.offset, spec.length, fade_in, fade_out, std::max(spec.gain, 0.0f), audio});
    }
    std::vector<StreamRegion> regions;  // for the disk thread to read ahead of
    for (const auto& clip : track->clips) regions.push_back({clip.file, clip.start, clip.offset, clip.length});
    streamer_.setRegions(id, std::move(regions));
    Command c; c.type = Command::TrackSet; c.id = id; c.data = track.get(); c.epoch = s->board_sent + 1;
    if (!commands_.push(c)) {
        if (error) *error = "the audio engine is busy: try again";
        return false;
    }
    s->board_sent = c.epoch;
    if (s->track) s->retired_tracks.emplace_back(std::move(s->track), s->board_sent);
    s->track = std::move(track);
    return all;
}

std::vector<float> AudioEngine::audioPeaks(const std::string& path, double per_second) {
    std::vector<float> out;
    auto audio = audioFile(path, nullptr);
    if (!audio || per_second <= 0.0) return out;
    const size_t bucket = std::max<size_t>(1, size_t(audio->rate() / per_second));
    out.assign((size_t(audio->frames()) + bucket - 1) / bucket, 0.0f);
    std::vector<float> piece(StreamedFile::kChunkFrames);  // read through once, a piece at a time, and not kept
    for (int64_t at = 0; at < audio->frames();) {
        const size_t got = audio->read(at, piece.size(), piece.data());
        if (got == 0) break;
        for (size_t i = 0; i < got; ++i) {
            const size_t b = size_t(at + int64_t(i)) / bucket;
            out[b] = std::max(out[b], std::fabs(piece[i]));
        }
        at += int64_t(got);
    }
    return out;
}

double AudioEngine::audioSeconds(const std::string& path) {
    auto audio = audioFile(path, nullptr);
    return audio ? audio->seconds() : 0.0;  // (its header says)
}

void AudioEngine::setAutomationRead(int id, bool volume, bool mute, bool sustain, bool params) {
    Command c; c.type = Command::AutomationRead; c.id = id;
    c.v[0] = volume ? 1.0f : 0.0f; c.v[1] = mute ? 1.0f : 0.0f; c.v[2] = sustain ? 1.0f : 0.0f; c.v[3] = params ? 1.0f : 0.0f;
    push(c);
}

void AudioEngine::setSend(int id, int slot, int bus, float gain, bool pre, bool on) {
    if (slot < 0 || slot >= kMaxSends) return;
    const Source* target = bus >= 0 ? owned(bus) : nullptr;
    if (bus >= 0 && (!target || !isBus(target->kind) || bus == id)) bus = -1;
    Command c; c.type = Command::SendSet; c.id = id;
    c.v[0] = float(slot); c.v[1] = float(bus); c.v[2] = std::clamp(gain, 0.0f, 16.0f); c.v[3] = pre ? 1.0f : 0.0f; c.v[4] = on ? 1.0f : 0.0f;
    push(c);
    if (Source* s = owned(id); s && s->send_to[size_t(slot)] != bus) {
        s->send_to[size_t(slot)] = bus;
        updateDelayCompensation();
    }
}

void AudioEngine::setMasterAutomation(const std::vector<AutoPoint>& volume, Monitor which) {
    reapPedals();
    const size_t m = size_t(which);
    auto lane = std::make_unique<std::vector<AutoPoint>>(volume);
    std::stable_sort(lane->begin(), lane->end(), [](const AutoPoint& a, const AutoPoint& b) { return a.step < b.step; });
    Command c; c.type = Command::MasterAutomation; c.data = lane.get(); c.epoch = master_sent_[m] + 1; c.v[0] = float(m);
    if (!commands_.push(c)) return;
    master_sent_[m] = c.epoch;
    if (master_auto_[m]) retired_master_[m].emplace_back(std::move(master_auto_[m]), master_sent_[m]);
    master_auto_[m] = std::move(lane);
}

void AudioEngine::setMasterAutomationRead(bool read, Monitor which) {
    Command c; c.type = Command::MasterRead; c.v[0] = read ? 1.0f : 0.0f; c.v[1] = float(which); push(c);
}

void AudioEngine::setRecordArm(int id, bool armed) {
    Command c; c.type = Command::RecordArm; c.id = id; c.v[0] = armed ? 1.0f : 0.0f; push(c);
}

bool AudioEngine::startRecording(const std::vector<std::pair<int, std::string>>& files, double from_step, std::string* error,
                                 double count_in_steps, bool loop, double preroll_steps, double punch_out_step) {
    if (recording_wanted_ || recorder_) {
        if (error) *error = "it is recording already";
        return false;
    }
    std::vector<int> stereo;  // (a stereo mic records a file of two channels)
    for (const auto& [source, path] : files)
        if (const Source* s = owned(source); s && s->kind == InstrumentKind::StereoMic) stereo.push_back(source);
    auto recorder = std::make_unique<Recorder>();
    if (!recorder->begin(files, sr_, error, stereo)) return false;
    Captured stale;
    while (captured_.pop(stale)) {}
    Command c; c.type = Command::RecordStart; c.data = recorder.get(); c.v[0] = float(std::max(from_step, 0.0));
    c.v[1] = float(std::max(count_in_steps, 0.0));
    c.v[2] = loop ? 1.0f : 0.0f;
    c.v[3] = float(std::max(preroll_steps, 0.0));
    c.v[4] = float(punch_out_step);
    if (!commands_.push(c)) {
        if (error) *error = "the audio engine is busy: try again";
        return false;
    }
    recorder_ = std::move(recorder);
    recording_wanted_ = true;
    transport_.running = true;
    return true;
}

void AudioEngine::stopRecording() {
    if (!recording_wanted_) return;
    Command c; c.type = Command::RecordStop; c.epoch = ++record_epoch_; push(c);
    recording_wanted_ = false;
}

bool AudioEngine::takeRecording(RecordingResult* out) {
    if (!recorder_ || recording_wanted_ || record_ack_.load(std::memory_order_acquire) < record_epoch_) return false;
    recorder_->finish();
    RecordingResult result;
    result.start_step = record_start_.load();
    result.end_step = record_end_.load();
    result.step_seconds = record_step_seconds_.load();
    for (const Recorder::Take& take : recorder_->takes())
        result.audio.push_back({take.source, take.path, double(take.frames) / double(sr_), take.dropped});
    // Each note from its key going down to its going up (or to the end of the recording, if it never did).
    std::vector<std::pair<int, size_t>> open;  // (source * 128 + note) → its place in result.notes
    Captured e;
    while (captured_.pop(e)) {
        if (e.note < 0) {  // the sustain pedal
            result.sustain.push_back({e.source, e.step, e.on});
            continue;
        }
        const int key = e.source * 128 + e.note;
        auto held = std::find_if(open.begin(), open.end(), [&](const auto& o) { return o.first == key; });
        if (held != open.end()) {  // a note let go (or struck again while held)
            TimelineNote& n = result.notes[held->second].note;
            n.length = float(std::max(e.step - n.step, 0.05));
            open.erase(held);
        }
        if (e.on) {
            result.notes.push_back({e.source, TimelineNote{e.step, 1.0f, e.note, e.velocity}});
            open.emplace_back(key, result.notes.size() - 1);
        }
    }
    for (const auto& o : open) {
        TimelineNote& n = result.notes[o.second].note;
        n.length = float(std::max(result.end_step - n.step, 0.05));
    }
    recorder_.reset();
    *out = std::move(result);
    return true;
}

int AudioEngine::addPedal(int id, PedalKind kind, int at) {
    reapPedals();
    Source* s = owned(id);
    if (!s || !isAmp(s->kind) || int(s->pedals.size()) >= kMaxPedals) return -1;
    if (kind == PedalKind::Looper && looperOf(*s)) return -1;  // one loop pedal to an amp
    Source::PedalSlot slot;
    slot.pedal = Pedal::make(kind, float(sr_));
    if (!slot.pedal) return -1;
    slot.controls = defaultPedalControls(kind);
    if (at < 0 || at > int(s->pedals.size())) at = int(s->pedals.size());
    const int front = int(s->pedals.size()) - s->fx_loop;
    s->pedals.insert(s->pedals.begin() + at, std::move(slot));
    if (at > front) ++s->fx_loop;  // (into the loop)
    if (!sendBoard(*s)) {
        s->pedals.erase(s->pedals.begin() + at);
        if (at > front) --s->fx_loop;
        return -1;
    }
    return at;
}

bool AudioEngine::removePedal(int id, int index) {
    reapPedals();
    Source* s = owned(id);
    if (!s || index < 0 || index >= int(s->pedals.size())) return false;
    const bool in_loop = index >= int(s->pedals.size()) - s->fx_loop;
    Source::PedalSlot slot = std::move(s->pedals[size_t(index)]);
    s->pedals.erase(s->pedals.begin() + index);
    if (in_loop) --s->fx_loop;
    if (!sendBoard(*s)) {
        s->pedals.insert(s->pedals.begin() + index, std::move(slot));
        if (in_loop) ++s->fx_loop;
        return false;
    }
    if (slot.pedal->kind() == PedalKind::Plugin)
        if (PluginInstance* plugin = static_cast<PluginPedal*>(slot.pedal.get())->plugin()) plugin->hideEditor();
    s->retired.emplace_back(std::move(slot.pedal), s->board_sent);
    return true;
}

bool AudioEngine::movePedal(int id, int from, int to, int loop) {
    Source* s = owned(id);
    const int count = s ? int(s->pedals.size()) : 0;
    if (!s || from < 0 || from >= count || to < 0 || to >= count) return false;
    const int loop_was = s->fx_loop;
    if (loop >= 0) s->fx_loop = std::min(loop, count);
    if (from == to) {
        if (s->fx_loop == loop_was || sendBoard(*s)) return true;
        s->fx_loop = loop_was;
        return false;
    }
    auto first = s->pedals.begin();
    if (from < to) std::rotate(first + from, first + from + 1, first + to + 1);
    else std::rotate(first + to, first + from, first + from + 1);
    if (sendBoard(*s)) return true;
    if (from < to) std::rotate(first + from, first + to, first + to + 1);  // put it back
    else std::rotate(first + to, first + to + 1, first + from + 1);
    s->fx_loop = loop_was;
    return false;
}

bool AudioEngine::setPedalLoop(int id, int loop) {
    Source* s = owned(id);
    if (!s || !isAmp(s->kind)) return false;
    const int was = s->fx_loop;
    s->fx_loop = std::clamp(loop, 0, int(s->pedals.size()));
    if (s->fx_loop == was) return true;
    if (sendBoard(*s)) return true;
    s->fx_loop = was;
    return false;
}

int AudioEngine::pedalLoop(int id) const {
    const Source* s = owned(id);
    return s ? s->fx_loop : 0;
}

int AudioEngine::copyPedal(int from_id, int index, int to_id, int at, std::string* error, int loop) {
    reapPedals();
    const Source* a = owned(from_id);
    Source* b = owned(to_id);
    if (!a || index < 0 || index >= int(a->pedals.size()) || !b || !isAmp(b->kind)) {
        if (error) *error = "there is nothing there to copy";
        return -1;
    }
    if (int(b->pedals.size()) >= kMaxPedals) {
        if (error) *error = "the board is full";
        return -1;
    }
    const Source::PedalSlot& original = a->pedals[size_t(index)];
    const PedalKind kind = original.pedal->kind();
    if (kind == PedalKind::Looper && looperOf(*b)) {
        if (error) *error = "an amp has only one loop pedal";
        return -1;
    }
    Source::PedalSlot slot;
    const PluginInstance* plugin =
        kind == PedalKind::Plugin ? static_cast<const PluginPedal*>(original.pedal.get())->plugin() : nullptr;
    if (plugin) {
        const std::vector<uint8_t> state = plugin->saveState();
        slot.pedal = makePluginPedal(plugin->description().id, &state, error);
        if (!slot.pedal) return -1;
    } else {
        slot.pedal = Pedal::make(kind, float(sr_));
        if (!slot.pedal) {
            if (error) *error = "it couldn't be made";
            return -1;
        }
    }
    slot.on = original.on;
    slot.controls = original.controls;
    slot.pedal->setOn(slot.on);  // the audio thread doesn't have it yet
    for (int i = 0; i < kPedalControls; ++i) slot.pedal->setControl(i, slot.controls[size_t(i)]);
    if (at < 0 || at > int(b->pedals.size())) at = int(b->pedals.size());
    const int loop_was = b->fx_loop;
    if (at > int(b->pedals.size()) - b->fx_loop) ++b->fx_loop;  // (into the loop)
    b->pedals.insert(b->pedals.begin() + at, std::move(slot));
    if (loop >= 0) b->fx_loop = std::min(loop, int(b->pedals.size()));
    if (!sendBoard(*b)) {
        b->pedals.erase(b->pedals.begin() + at);
        b->fx_loop = loop_was;
        if (error) *error = "the audio engine is busy: try again";
        return -1;
    }
    return at;
}

void AudioEngine::setPedalOn(int id, int index, bool on) {
    Source* s = owned(id);
    if (!s || index < 0 || index >= int(s->pedals.size())) return;
    auto& slot = s->pedals[size_t(index)];
    slot.on = on;
    Command c; c.type = Command::PedalOn; c.id = id; c.pedals[0] = slot.pedal.get(); c.v[0] = on ? 1.0f : 0.0f; push(c);
}

void AudioEngine::setPedalControl(int id, int index, int control, float value) {
    Source* s = owned(id);
    if (!s || index < 0 || index >= int(s->pedals.size()) || control < 0 || control >= kPedalControls) return;
    auto& slot = s->pedals[size_t(index)];
    slot.controls[size_t(control)] = std::clamp(value, 0.0f, 10.0f);
    Command c; c.type = Command::PedalControl; c.id = id; c.pedals[0] = slot.pedal.get();
    c.v[0] = float(control); c.v[1] = slot.controls[size_t(control)];
    push(c);
}

std::vector<PedalStatus> AudioEngine::pedals(int id) const {
    std::vector<PedalStatus> out;
    const Source* s = owned(id);
    if (!s) return out;
    for (const auto& slot : s->pedals) {
        PedalStatus p;
        p.kind = slot.pedal->kind();
        p.on = slot.on;
        p.in_loop = int(out.size()) >= int(s->pedals.size()) - s->fx_loop;
        p.controls = slot.controls;
        if (p.kind == PedalKind::Plugin)
            if (const PluginInstance* plugin = static_cast<const PluginPedal*>(slot.pedal.get())->plugin()) {
                p.plugin = plugin->description();
                p.editor_open = plugin->editorVisible();
            }
        out.push_back(p);
    }
    return out;
}

TunerReading AudioEngine::tuner(int id) const {
    const Source* s = owned(id);
    if (s)
        for (const auto& slot : s->pedals)
            if (slot.on && slot.pedal->kind() == PedalKind::Tuner) return static_cast<const TunerPedal*>(slot.pedal.get())->read();
    return {};
}

bool AudioEngine::loadPedalPlugin(int id, int index, const std::string& plugin_id, std::string* error, const std::vector<uint8_t>* state) {
    reapPedals();
    Source* s = owned(id);
    if (!s || index < 0 || index >= int(s->pedals.size()) || s->pedals[size_t(index)].pedal->kind() != PedalKind::Plugin) {
        if (error) *error = "there is no Plug-in pedal there";
        return false;
    }
    std::unique_ptr<PluginPedal> pedal = makePluginPedal(plugin_id, state, error);
    if (!pedal) return false;
    auto& slot = s->pedals[size_t(index)];
    pedal->setOn(slot.on);
    std::unique_ptr<Pedal> old = std::move(slot.pedal);
    slot.pedal = std::move(pedal);
    if (!sendBoard(*s)) {
        slot.pedal = std::move(old);
        if (error) *error = "the audio engine is busy: try again";
        return false;
    }
    if (PluginInstance* previous = static_cast<PluginPedal*>(old.get())->plugin()) previous->hideEditor();
    s->retired.emplace_back(std::move(old), s->board_sent);
    return true;
}

bool AudioEngine::showPluginEditor(int id, int index, bool show, const std::string& title) {
    Source* s = owned(id);
    if (!s || index < 0 || index >= int(s->pedals.size()) || s->pedals[size_t(index)].pedal->kind() != PedalKind::Plugin) return false;
    PluginInstance* plugin = static_cast<PluginPedal*>(s->pedals[size_t(index)].pedal.get())->plugin();
    if (!plugin) return false;
    if (!show) {
        plugin->hideEditor();
        return true;
    }
    return plugin->showEditor(title.empty() ? plugin->description().name : title);
}

// ── Inserts (game thread) ──────────────────────────────────────────────────────────────────────────────────
std::unique_ptr<PluginPedal> AudioEngine::makePluginPedal(const std::string& plugin_id, const std::vector<uint8_t>* state,
                                                          std::string* error, bool stereo) {
    std::unique_ptr<PluginInstance> plugin = PluginInstance::load(plugin_id, error);
    if (!plugin) return nullptr;
    auto pedal = std::make_unique<PluginPedal>(std::move(plugin));
    pedal->setStereo(stereo);
    pedal->prepare(float(sr_));
    if (!pedal->ready()) {
        if (error) *error = pedal->error();
        return nullptr;
    }
    if (state) pedal->plugin()->loadState(*state);  // before the audio thread has it
    return pedal;
}

bool AudioEngine::setInsert(int id, int slot, const std::string& plugin_id, std::string* error, const std::vector<uint8_t>* state) {
    reapPedals();
    Source* s = owned(id);
    if (!s || slot < 0 || slot >= kMaxInserts) {
        if (error) *error = "there is no such insert";
        return false;
    }
    std::unique_ptr<PluginPedal> pedal = makePluginPedal(plugin_id, state, error, isStereo(s->kind));
    return pedal && placeInsert(*s, slot, std::move(pedal), true, error);
}

bool AudioEngine::placeInsert(Source& s, int slot, std::unique_ptr<PluginPedal> pedal, bool on, std::string* error) {
    pedal->setOn(on);
    auto& place = s.inserts[size_t(slot)];
    std::unique_ptr<Pedal> old = std::move(place.pedal);
    place.pedal = std::move(pedal);
    place.on = on;
    if (!sendBoard(s, true)) {
        place.pedal = std::move(old);
        if (error) *error = "the audio engine is busy: try again";
        return false;
    }
    if (old) {
        if (PluginInstance* previous = static_cast<PluginPedal*>(old.get())->plugin()) previous->hideEditor();
        s.retired.emplace_back(std::move(old), s.board_sent);
    }
    return true;
}

bool AudioEngine::moveInsert(int from_id, int from_slot, int to_id, int to_slot) {
    reapPedals();
    Source* a = owned(from_id);
    Source* b = owned(to_id);
    if (!a || !b || from_slot < 0 || from_slot >= kMaxInserts || to_slot < 0 || to_slot >= kMaxInserts || !a->inserts[size_t(from_slot)].pedal)
        return false;
    if (a == b && from_slot == to_slot) return true;
    if (isStereo(a->kind) != isStereo(b->kind)) {  // between a channel of one and one of two: made again there, settings and all
        if (b->inserts[size_t(to_slot)].pedal) return false;  // (only into an empty slot)
        return copyInsert(from_id, from_slot, to_id, to_slot, nullptr) && clearInsert(from_id, from_slot);
    }
    auto& from = a->inserts[size_t(from_slot)];
    auto& to = b->inserts[size_t(to_slot)];
    Source::PedalSlot moving = std::move(from), displaced = std::move(to);
    from.pedal.reset();
    to.pedal.reset();
    // Off both channels first, then on again where they now belong: no plug-in is ever on two boards at once, so none
    // is played twice in a block.
    sendBoard(*a, true);
    if (b != a) sendBoard(*b, true);
    to = std::move(moving);
    from = std::move(displaced);
    sendBoard(*b, true);
    if (b != a) sendBoard(*a, true);
    return true;
}

bool AudioEngine::copyInsert(int from_id, int from_slot, int to_id, int to_slot, std::string* error) {
    reapPedals();
    Source* a = owned(from_id);
    Source* b = owned(to_id);
    const PluginInstance* original = a && from_slot >= 0 && from_slot < kMaxInserts && a->inserts[size_t(from_slot)].pedal
                                         ? static_cast<PluginPedal*>(a->inserts[size_t(from_slot)].pedal.get())->plugin()
                                         : nullptr;
    if (!original || !b || to_slot < 0 || to_slot >= kMaxInserts) {
        if (error) *error = "there is nothing there to copy";
        return false;
    }
    if (a == b && from_slot == to_slot) return true;
    const std::vector<uint8_t> state = original->saveState();
    std::unique_ptr<PluginPedal> copy = makePluginPedal(original->description().id, &state, error, isStereo(b->kind));
    return copy && placeInsert(*b, to_slot, std::move(copy), a->inserts[size_t(from_slot)].on, error);
}

PluginInstance* AudioEngine::pluginAt(int id, PluginPlace place, int index) const {
    const Source* s = owned(id);
    if (!s || index < 0) return nullptr;
    const Pedal* pedal = nullptr;
    if (place == PluginPlace::Insert && index < kMaxInserts) pedal = s->inserts[size_t(index)].pedal.get();
    else if (place == PluginPlace::Pedal && index < int(s->pedals.size())) pedal = s->pedals[size_t(index)].pedal.get();
    else if (place == PluginPlace::Instrument) pedal = s->synth.pedal.get();
    return pedal && pedal->kind() == PedalKind::Plugin ? static_cast<const PluginPedal*>(pedal)->plugin() : nullptr;
}

std::vector<uint8_t> AudioEngine::pluginState(int id, PluginPlace place, int index) const {
    const PluginInstance* plugin = pluginAt(id, place, index);
    return plugin ? plugin->saveState() : std::vector<uint8_t>{};
}

bool AudioEngine::setPluginState(int id, PluginPlace place, int index, const std::vector<uint8_t>& state) {
    PluginInstance* plugin = pluginAt(id, place, index);
    return plugin && plugin->loadState(state);
}

std::vector<std::string> AudioEngine::factoryPresets(int id, PluginPlace place, int index) const {
    const PluginInstance* plugin = pluginAt(id, place, index);
    return plugin ? plugin->factoryPresets() : std::vector<std::string>{};
}

bool AudioEngine::loadFactoryPreset(int id, PluginPlace place, int index, int preset) {
    PluginInstance* plugin = pluginAt(id, place, index);
    return plugin && plugin->loadFactoryPreset(preset);
}

std::vector<PluginParameter> AudioEngine::pluginParameters(int id, PluginPlace place, int index) const {
    const PluginInstance* plugin = pluginAt(id, place, index);
    return plugin ? plugin->parameters() : std::vector<PluginParameter>{};
}

std::string AudioEngine::pluginParameterText(int id, PluginPlace place, int index, uint32_t param, float value) const {
    const PluginInstance* plugin = pluginAt(id, place, index);
    return plugin ? plugin->parameterText(param, value) : "";
}

float AudioEngine::pluginParameter(int id, PluginPlace place, int index, uint32_t param) const {
    const PluginInstance* plugin = pluginAt(id, place, index);
    return plugin ? plugin->parameter(param) : 0.0f;
}

void AudioEngine::setPluginParameter(int id, PluginPlace place, int index, uint32_t param, float value) {
    if (PluginInstance* plugin = pluginAt(id, place, index)) {
        plugin->setParameter(param, value);
        plugin->notifyParameter(param);
    }
}

void AudioEngine::notifyPluginParameter(int id, PluginPlace place, int index, uint32_t param) {
    if (PluginInstance* plugin = pluginAt(id, place, index)) plugin->notifyParameter(param);
}

// ── Plug-in instruments (game thread) ──────────────────────────────────────────────────────────────────────
bool AudioEngine::setInstrumentPlugin(int id, const std::string& plugin_id, std::string* error, const std::vector<uint8_t>* state) {
    reapPedals();
    Source* s = owned(id);
    if (!s || s->kind != InstrumentKind::PluginSynth) {
        if (error) *error = "that isn't a plug-in instrument";
        return false;
    }
    std::unique_ptr<PluginPedal> holder = makePluginPedal(plugin_id, state, error);
    if (!holder) return false;
    if (!holder->plugin()->isInstrument()) {
        if (error) *error = "it is an effect, not an instrument";
        return false;
    }
    std::unique_ptr<Pedal> old = std::move(s->synth.pedal);
    s->synth.pedal = std::move(holder);
    Command c; c.type = Command::SynthPlugin; c.id = id; c.pedals[0] = s->synth.pedal.get(); c.epoch = s->board_sent + 1;
    if (!commands_.push(c)) {
        s->synth.pedal = std::move(old);
        if (error) *error = "the audio engine is busy: try again";
        return false;
    }
    s->board_sent = c.epoch;
    if (old) {
        if (PluginInstance* previous = static_cast<PluginPedal*>(old.get())->plugin()) previous->hideEditor();
        s->retired.emplace_back(std::move(old), s->board_sent);
    }
    updateDelayCompensation();
    return true;
}

void AudioEngine::placeInstrumentEditor(int id, double above_bottom) {
    if (PluginInstance* plugin = pluginAt(id, PluginPlace::Instrument, 0)) plugin->placeEditor(above_bottom);
}

PluginDescription AudioEngine::instrumentPlugin(int id) const {
    const PluginInstance* plugin = pluginAt(id, PluginPlace::Instrument, 0);
    return plugin ? plugin->description() : PluginDescription{};
}

bool AudioEngine::instrumentEditorOpen(int id) const {
    const PluginInstance* plugin = pluginAt(id, PluginPlace::Instrument, 0);
    return plugin && plugin->editorVisible();
}

bool AudioEngine::showInstrumentEditor(int id, bool show, const std::string& title) {
    PluginInstance* plugin = pluginAt(id, PluginPlace::Instrument, 0);
    if (!plugin) return false;
    if (!show) {
        plugin->hideEditor();
        return true;
    }
    return plugin->showEditor(title.empty() ? plugin->description().name : title);
}

bool AudioEngine::clearInsert(int id, int slot) {
    reapPedals();
    Source* s = owned(id);
    if (!s || slot < 0 || slot >= kMaxInserts || !s->inserts[size_t(slot)].pedal) return false;
    std::unique_ptr<Pedal> old = std::move(s->inserts[size_t(slot)].pedal);
    if (!sendBoard(*s, true)) {
        s->inserts[size_t(slot)].pedal = std::move(old);
        return false;
    }
    if (PluginInstance* plugin = static_cast<PluginPedal*>(old.get())->plugin()) plugin->hideEditor();
    s->retired.emplace_back(std::move(old), s->board_sent);
    return true;
}

void AudioEngine::setInsertOn(int id, int slot, bool on) {
    Source* s = owned(id);
    if (!s || slot < 0 || slot >= kMaxInserts || !s->inserts[size_t(slot)].pedal) return;
    auto& place = s->inserts[size_t(slot)];
    place.on = on;
    Command c; c.type = Command::PedalOn; c.id = id; c.pedals[0] = place.pedal.get(); c.v[0] = on ? 1.0f : 0.0f; push(c);
}

std::vector<PedalStatus> AudioEngine::inserts(int id) const {
    std::vector<PedalStatus> out;
    const Source* s = owned(id);
    if (!s) return out;
    for (const auto& place : s->inserts) {
        PedalStatus p;
        p.kind = PedalKind::Plugin;
        p.on = place.on;
        if (place.pedal)
            if (const PluginInstance* plugin = static_cast<const PluginPedal*>(place.pedal.get())->plugin()) {
                p.plugin = plugin->description();
                p.editor_open = plugin->editorVisible();
            }
        out.push_back(p);
    }
    return out;
}

bool AudioEngine::showInsertEditor(int id, int slot, bool show, const std::string& title) {
    Source* s = owned(id);
    if (!s || slot < 0 || slot >= kMaxInserts || !s->inserts[size_t(slot)].pedal) return false;
    PluginInstance* plugin = static_cast<PluginPedal*>(s->inserts[size_t(slot)].pedal.get())->plugin();
    if (!plugin) return false;
    if (!show) {
        plugin->hideEditor();
        return true;
    }
    return plugin->showEditor(title.empty() ? plugin->description().name : title);
}

void AudioEngine::setSourceInput(int id, bool on) {
    if (Source* s = owned(id)) s->input_on = on;
    Command c; c.type = Command::SourceInput; c.id = id; c.v[0] = on ? 1.0f : 0.0f; push(c);
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
    src->amp_head = defaultHead(kind);
    src->amp_cabinet = defaultCabinet(kind);
    src->amp_speaker = defaultSpeaker(src->amp_cabinet);
    src->instrument = makeInstrument(kind);
    connect(*src);
    if (!src->spatializer.init(steam_, nullptr)) return -1;
    src->mono.assign(size_t(block_), 0.0f);
    src->bus_l.assign(size_t(block_), 0.0f);
    src->bus_r.assign(size_t(block_), 0.0f);
    for (auto* buffer : {&src->pre, &src->out_l, &src->out_r}) buffer->assign(size_t(block_), 0.0f);
    if (!inRoom(kind)) reverb_send = 0.0f;  // (a folder's tracks feed the reverb themselves; a microphone makes no sound)
    if (inRoom(kind)) {
        src->history.assign(Source::kHistory, 0.0f);
        src->history_low.assign(Source::kHistory, 0.0f);
        src->history_below_high.assign(Source::kHistory, 0.0f);
        src->room.assign(size_t(block_), 0.0f);
    }
    if (isMic(kind)) {  // a flat omni to begin with, where it stands (a stereo mic's two, there, till they are placed)
        src->capsule_count = kind == InstrumentKind::StereoMic ? 2 : 1;
        for (int k = 0; k < src->capsule_count; ++k) {
            Source::Capsule& capsule = src->capsules[size_t(k)];
            capsule.pickups = std::make_unique<std::array<Source::Pickup, kSourceSlots>>();
            for (auto& bus : capsule.scatter) bus.assign(size_t(block_), 0.0f);
            for (auto& smear : capsule.smear) smear.init(float(sr_));
            capsule.position = position;
            capsule.hiss.s = 0x9E3779B9u + uint32_t(slot * 2 + size_t(k)) * 0x85EBCA6Bu;
            soundAs(*src, k, micModelIndex("flat"), 0);
        }
        if (kind == InstrumentKind::StereoMic)
            for (auto* buffer : {&src->mono_r, &src->pre_r, &src->playback_r}) buffer->assign(size_t(block_), 0.0f);
    }
    src->via = src->via_target = src->position = position;
    src->gain = src->gain_target = gain;
    src->room_gain = src->room_gain_target = gain;
    src->send = reverb_send;

    Command c;
    c.type = Command::AddSource;
    c.id = src->id;
    c.source = src.get();
    if (!commands_.push(c)) return -1;
    if (slot == owned_.size()) owned_.push_back(std::move(src));
    else owned_[slot] = std::move(src);
    updatePath(*owned_[slot]);
    updateMicPaths(*owned_[slot]);
    updateDelayCompensation();
    return c.id;
}

bool AudioEngine::removeSource(int id) {
    Source* s = owned(id);
    if (!s) return false;
    Command c; c.type = Command::RemoveSource; c.id = id;
    if (!commands_.push(c)) return false;
    s->removing = true;
    streamer_.setRegions(id, {});
    reap();
    updateDelayCompensation();
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
    if (s->kind == InstrumentKind::Mic) s->capsules[0].position = p;  // (a stereo mic's capsules are placed apart)
    updatePath(*s);
    updateMicPaths(*s);
}

void AudioEngine::setSourceVolume(int id, float gain) {
    Command c; c.type = Command::SourceVolume; c.id = id; c.v[0] = std::clamp(gain, 0.0f, 100.0f); push(c);
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
    if (!inRoom(s.kind)) return;  // not heard in the room
    updateFacing(s);
    updateEchoes(s);
    if (geometry_.empty()) {  // no walls: straight from where it stands
        s.blocked = false;
        Command c; c.type = Command::SourcePosition; c.id = s.id;
        c.v[0] = s.position.x; c.v[1] = s.position.y; c.v[2] = s.position.z;
        push(c);
        return;
    }
    const DirectPath path = geometry_.directPath(ear_, s.position);
    s.blocked = path.blocked;
    setSourceDirectPath(s.id, path.via, path.extra, path.differences, path.count, path.blocked, path.through);
}

void AudioEngine::updatePaths() {
    for (auto& s : owned_)
        if (s && !s->removing) updatePath(*s);
}

// A microphone capsule's model and pattern, made ready to play: its pattern band by band, what of a diffuse field it
// hears, its response's filters at the engine's sample rate, its sensitivity, its noise.
void AudioEngine::soundAs(Source& mic, int capsule, int model_index, int pattern_index) {
    const auto& models = micModels();
    if (model_index < 0 || model_index >= int(models.size()) || capsule < 0 || capsule >= mic.capsule_count) return;
    const MicModel& model = models[size_t(model_index)];
    const auto& pattern = model.patterns[size_t(std::clamp(pattern_index, 0, int(model.patterns.size()) - 1))];
    auto& sound = mic.capsules[size_t(capsule)].sound;
    sound.model = model_index;
    sound.pattern = pattern_index;
    sound.polar = pattern.second;
    sound.gradient = false;
    for (int b = 0; b < 3; ++b) {
        const float a = sound.polar.pressure[size_t(b)], g = sound.polar.gradient[size_t(b)];
        sound.diffuse[b] = std::sqrt(a * a + g * g / 3.0f);  // (A + B cos over every way round, in energy)
        sound.gradient = sound.gradient || std::fabs(g) > 1e-4f;
    }
    sound.eq_count = std::min(int(model.response.size()), int(sound.eq.size()));
    for (int f = 0; f < sound.eq_count; ++f) {
        sound.eq[size_t(f)] = {};
        sound.eq[size_t(f)].design(model.response[size_t(f)], float(sr_));
    }
    sound.sensitivity = std::pow(10.0f, model.sensitivity_db / 20.0f);
    // Its noise as a sound level, in the room's terms (a full-scale sample is kFullScaleSpl), as white noise (whose
    // amplitude is sqrt 3 times its RMS).
    sound.noise = std::pow(10.0f, (micNoiseSpl(model) - kFullScaleSpl) / 20.0f) * std::sqrt(3.0f);
}

void AudioEngine::setMicModel(int id, const std::string& model, MicPattern pattern, int capsule) {
    const int index = micModelIndex(model);
    if (index < 0) return;
    const auto& patterns = micModels()[size_t(index)].patterns;
    int which = 0;
    for (size_t p = 0; p < patterns.size(); ++p)
        if (patterns[p].first == pattern) which = int(p);
    Command c; c.type = Command::MicModelSet; c.id = id; c.v[0] = float(index); c.v[1] = float(which); c.v[2] = float(capsule); push(c);
}

void AudioEngine::setMicAim(int id, Vec3 aim, int capsule) {
    const float n = length(aim);
    if (n < 1e-6f) return;
    Command c; c.type = Command::MicAim; c.id = id; c.v[0] = aim.x / n; c.v[1] = aim.y / n; c.v[2] = aim.z / n; c.v[3] = float(capsule);
    push(c);
}

void AudioEngine::setMicCapsule(int id, int capsule, Vec3 position) {
    Source* s = owned(id);
    if (!s || capsule < 0 || capsule >= s->capsule_count) return;
    const Vec3 was = s->capsules[size_t(capsule)].position;
    if (was.x == position.x && was.y == position.y && was.z == position.z) return;
    s->capsules[size_t(capsule)].position = position;
    updateMicPaths(*s);
}

void AudioEngine::setMicMidSide(int id, bool mid_side, float width) {
    Command c; c.type = Command::MicMidSide; c.id = id; c.v[0] = mid_side ? 1.0f : 0.0f; c.v[1] = std::clamp(width, 0.0f, 4.0f); push(c);
}

void AudioEngine::setSourcePan(int id, float pan) {
    Command c; c.type = Command::SourcePan; c.id = id; c.v[0] = std::clamp(pan, -1.0f, 1.0f); push(c);
}

void AudioEngine::setBusMono(int id, bool mono) {
    Command c; c.type = Command::BusMono; c.id = id; c.v[0] = mono ? 1.0f : 0.0f; push(c);
}

void AudioEngine::updateFacing(Source& s) {
    if (s.radiator.cones <= 0 && !s.facing_sent) return;
    Command c; c.type = Command::SourceFacing; c.id = s.id;
    if (s.radiator.cones > 0) {
        const Facing f = facingFrom(s.radiator, s.position, ear_);
        c.v[0] = f.cut_hz;
        c.v[1] = f.gain;
        c.v[2] = powerCutHz(s.radiator);
        c.v[3] = coneRadius(s.radiator.inches);
    }  // (else all 0: no longer a loudspeaker)
    push(c);
    s.facing_sent = s.radiator.cones > 0;
}

Radiator AudioEngine::mirroredAcross(const Radiator& r, Vec3 point, Vec3 normal) {
    const auto flip = [&](Vec3& p) {
        const float d = (p.x - point.x) * normal.x + (p.y - point.y) * normal.y + (p.z - point.z) * normal.z;
        p = {p.x - 2.0f * d * normal.x, p.y - 2.0f * d * normal.y, p.z - 2.0f * d * normal.z};
    };
    Radiator image = r;
    for (auto& cone : image.cone) flip(cone);
    flip(image.back);
    const float f = dot(image.facing, normal);
    image.facing = {image.facing.x - 2.0f * f * normal.x, image.facing.y - 2.0f * f * normal.y, image.facing.z - 2.0f * f * normal.z};
    return image;
}

// A cabinet's image beyond a surface (`axis` 0, 1 or 2 for x, y or z, at `plane`; the floor: y = 0): its cones, its back
// and the way it faces, mirrored.
Radiator AudioEngine::mirrored(const Radiator& r, int axis, float plane) {
    const auto flip = [&](Vec3& p) { float& v = axis == 0 ? p.x : (axis == 1 ? p.y : p.z); v = 2.0f * plane - v; };
    Radiator image = r;
    for (auto& cone : image.cone) flip(cone);
    flip(image.back);
    float& facing = axis == 0 ? image.facing.x : (axis == 1 ? image.facing.y : image.facing.z);
    facing = -facing;
    return image;
}

void AudioEngine::setSourceRadiator(int id, const Radiator& radiator) {
    Source* s = owned(id);
    if (!s || !inRoom(s->kind)) return;
    s->radiator = radiator;
    s->radiator.cones = std::clamp(radiator.cones, 0, kMaxCones);
    if (isAmp(s->kind)) {  // (an amp's cones are its speakers')
        const SpeakerInfo info = speakerInfo(s->amp_speaker);
        s->radiator.breakup_hz = info.breakup_hz;
        s->radiator.cap_db = info.cap_db;
    }
    updateFacing(*s);
    updateMicPaths(*s);
}

void AudioEngine::updateMicPaths(Source& s) {
    if (isBus(s.kind)) return;
    for (auto& other : owned_) {
        if (!other || other->removing || other.get() == &s) continue;
        if (isMic(s.kind) && inRoom(other->kind)) updateMicPath(s, *other);
        else if (inRoom(s.kind) && isMic(other->kind)) updateMicPath(*other, s);
    }
}

// The way a source's sound reaches each of a microphone's capsules, as it reaches the listener: straight, or round a
// wall's edge (or over it), the longer way dulled as the shorter way is shadowed.
void AudioEngine::updateMicPath(const Source& mic, const Source& source) {
    for (int k = 0; k < mic.capsule_count; ++k) {
        const Vec3 at = mic.capsules[size_t(k)].position;
        Command c; c.type = Command::MicPath; c.id = mic.id; c.v[0] = float(source.id); c.v[8] = float(k);
        float gains[3] = {1.0f, 1.0f, 1.0f};
        Vec3 via = source.position;  // where it arrives from: the source itself, or the edge it bends round
        if (geometry_.empty()) {
            c.v[1] = length(sub(source.position, at));
        } else {
            const DirectPath path = geometry_.directPath(at, source.position);
            via = path.via;
            c.v[1] = length(sub(path.via, at)) + path.extra;
            directPathGains(path.differences, path.count, path.blocked, gains, path.through);
        }
        for (int b = 0; b < 3; ++b) c.v[2 + b] = gains[b];
        const Vec3 way = sub(via, at);
        const float n = length(way);
        c.v[5] = n > 1e-6f ? way.x / n : 0.0f;
        c.v[6] = n > 1e-6f ? way.y / n : 0.0f;
        c.v[7] = n > 1e-6f ? way.z / n : 1.0f;
        push(c);
        // Each way it comes: a loudspeaker cabinet's cones (and its open back) each their own (round a wall as much
        // further as the cabinet's middle is); anything else from where it stands, or the wall's edge it bends round.
        // And each of them again off the floor, from its image under the floor, as much of each band as its material
        // sends back, unless it is told to take it all; and the first reflection off each of the room's walls and its
        // ceiling, from the source's image beyond it (a cabinet as one, as it is heard from there), likewise.
        const bool radiates = radiatedPaths(source.radiator) > 0;
        const int direct = radiates ? radiatedPaths(source.radiator) : 1;
        const bool floor = floor_reflection_ > 0.0f;
        const int own = direct * (floor ? 2 : 1);  // its own ways, and off the floor; then its reflections off the rest
        const int ways = own + (early_reflections_ ? kEchoes - 1 : 0);
        const float detour = std::max(c.v[1] - length(sub(source.position, at)), 0.0f);
        const float ref = SourceSpatializer::kRefDistance;
        const auto send = [&](int w, const RadiatedPath& p, bool filtered, const std::array<float, 3>& bands = {1.0f, 1.0f, 1.0f},
                              const std::array<float, 3>& scatter = {0.0f, 0.0f, 0.0f}, int surface = 31, bool reflection = false) {
            Command cone; cone.type = Command::MicCone; cone.id = mic.id;
            std::copy(bands.begin(), bands.end(), cone.bands);
            std::copy(scatter.begin(), scatter.end(), cone.scatter);
            cone.epoch = uint32_t(source.id) | uint32_t(k) << 6 | uint32_t(w) << 7 | uint32_t(ways) << 14 | uint32_t(surface) << 21 |
                         uint32_t(reflection) << 26;
            cone.v[0] = p.distance;
            cone.v[1] = p.nearness;
            cone.v[2] = p.gain;
            cone.v[3] = filtered ? p.cut_hz : 0.0f;  // (0: no filters at all)
            cone.v[4] = p.low_db;
            cone.v[5] = p.high_db;
            cone.v[6] = p.from.x;
            cone.v[7] = p.from.y;
            cone.v[8] = p.from.z;
            push(cone);
        };
        const auto point = [&](Vec3 from, float extra) {  // a point source: louder as it comes closer, down to 10 cm
            RadiatedPath p;
            const Vec3 to = sub(from, at);
            p.distance = length(to) + extra;
            p.nearness = ref / std::max(p.distance, kMicNearest);
            p.gain = 1.0f;
            const float n = length(to);
            p.from = n > 1e-6f ? Vec3{to.x / n, to.y / n, to.z / n} : Vec3{0.0f, 0.0f, 1.0f};
            return p;
        };
        const std::array<Face, kFaces> room = faces();
        const Radiator image = mirrored(source.radiator);
        std::array<float, 3> floor_mirror = specular(room[0].material), floor_scatter = scattered(room[0].material);
        for (size_t b = 0; b < 3; ++b) {
            floor_mirror[b] *= floor_reflection_;
            floor_scatter[b] *= floor_reflection_;
        }
        for (int w = 0; w < direct; ++w) {
            RadiatedPath p = radiates ? radiate(source.radiator, w, at, ref) : point(via, c.v[1] - length(sub(via, at)));
            if (radiates) p.distance += detour;
            send(w, p, radiates);
            if (!floor) continue;
            const Vec3 under{source.position.x, -source.position.y, source.position.z};
            RadiatedPath bounce = radiates ? radiate(image, w, at, ref) : point(under, 0.0f);
            bounce.distance += detour;
            // (a cabinet's every cone scatters off the floor: the scattered part heard once, with its first cone's)
            send(direct + w, bounce, radiates, floor_mirror, w == 0 ? floor_scatter : std::array<float, 3>{}, 0);
        }
        if (early_reflections_) {  // its reflections off the rest of the room (the floor's once is its own ways')
            std::array<Bounce, kEchoes> all;
            bounces(source, at, all);
            for (int r = 1; r < kEchoes; ++r) {
                const Bounce& b = all[size_t(r)];
                RadiatedPath p = point(b.image, 0.0f);
                p.gain = b.on ? b.gain : 0.0f;
                p.cut_hz = b.cut_hz > 0.0f ? b.cut_hz : 20000.0f;
                send(own + r - 1, p, b.cut_hz > 0.0f, b.mirror, b.scatter, b.on ? b.bus : 31, true);
            }
        }
    }
}

void AudioEngine::setFloorReflection(float amount) {
    floor_reflection_ = std::clamp(amount, 0.0f, 1.0f);
    updatePaths();  // (the listener hears it too)
    for (auto& s : owned_)
        if (s && !s->removing && isMic(s->kind)) updateMicPaths(*s);
}

std::array<AudioEngine::Face, AudioEngine::kFaces> AudioEngine::faces() const {
    const float half_w = room_dims_[0] * 0.5f, half_d = room_dims_[2] * 0.5f;
    return {Face{1, 0.0f, surfaces_.floor}, Face{1, room_dims_[1], surfaces_.ceiling}, Face{2, -half_d, surfaces_.north},
            Face{2, half_d, surfaces_.south}, Face{0, half_w, surfaces_.east},       Face{0, -half_w, surfaces_.west}};
}

// Every reflection of a source's sound on its way to `at` (see bounces in engine.h).
void AudioEngine::bounces(const Source& s, Vec3 at, std::array<Bounce, kEchoes>& out) const {
    out = {};
    if (!early_reflections_) return;
    const std::array<Face, kFaces> room = faces();
    const bool radiates = radiatedPaths(s.radiator) > 0;
    const auto through = [&](std::initializer_list<Vec3> way) {  // what passes the walls standing along a way, band by band
        std::array<float, 3> kept{1.0f, 1.0f, 1.0f};
        const Vec3* last = nullptr;
        for (const Vec3& p : way) {
            if (last) {
                const std::array<float, 3> t = geometry_.transmission(*last, p);
                for (size_t b = 0; b < 3; ++b) kept[b] *= t[b];
            }
            last = &p;
        }
        return kept;
    };
    const auto beaming = [&](Bounce& b, const Radiator& image) {  // a loudspeaker as it is heard from its image
        if (!radiates) return;
        const Facing look = facingFrom(image, b.image, at);
        b.gain = look.gain;
        b.cut_hz = look.cut_hz;
    };
    // Once off each of the room's surfaces.
    for (int f = 0; f < kFaces; ++f) {
        const Face& face = room[size_t(f)];
        const float scale = f == 0 ? floor_reflection_ : 1.0f;
        if (scale <= 0.0f) continue;
        Bounce& b = out[size_t(f)];
        b.image = mirror(s.position, face.axis, face.plane);
        const Vec3 strike = strikeOn(at, b.image, face.axis, face.plane);
        const std::array<float, 3> kept = through({s.position, strike, at}), as_mirror = specular(face.material), spread = scattered(face.material);
        for (size_t k = 0; k < 3; ++k) {
            b.mirror[k] = as_mirror[k] * scale * kept[k];
            b.scatter[k] = spread[k] * scale * kept[k];
        }
        b.gain = 1.0f;
        beaming(b, mirrored(s.radiator, face.axis, face.plane));
        b.bus = f;
        b.on = true;
    }
    // Off one of them, then another: what both send back as mirrors is the mirror's part; the rest of what both send
    // back, scattered at one or the other, is heard scattered off the second.
    int slot = kFaces;
    for (int a = 0; a < kFaces; ++a)
        for (int c = 0; c < kFaces; ++c) {
            if (a == c || (room[size_t(a)].axis != room[size_t(c)].axis && c < a)) continue;
            Bounce& b = out[size_t(slot++)];
            const float scale = (a == 0 || c == 0) ? floor_reflection_ : 1.0f;
            if (scale <= 0.0f) continue;
            const Face &first = room[size_t(a)], &second = room[size_t(c)];
            const Vec3 once = mirror(s.position, first.axis, first.plane);
            b.image = mirror(once, second.axis, second.plane);
            const Vec3 later = strikeOn(at, b.image, second.axis, second.plane);
            const Vec3 sooner = strikeOn(later, once, first.axis, first.plane);
            const std::array<float, 3> kept = through({s.position, sooner, later, at});
            const std::array<float, 3> ra = reflection(first.material), rc = reflection(second.material);
            const std::array<float, 3> sa = specular(first.material), sc = specular(second.material);
            for (size_t k = 0; k < 3; ++k) {
                const float both = sa[k] * sc[k], all = ra[k] * rc[k];
                b.mirror[k] = both * scale * kept[k];
                b.scatter[k] = std::sqrt(std::max(all * all - both * both, 0.0f)) * scale * kept[k];
            }
            b.gain = 1.0f;
            beaming(b, mirrored(mirrored(s.radiator, first.axis, first.plane), second.axis, second.plane));
            b.bus = c;
            b.on = true;
        }
    // Off each face of each wall standing in the room that the source and the place are both in front of, while where it
    // strikes is on it: fading out over its edges (and a little beyond), as sound bends round an edge rather than
    // stopping at it (half as loud at the edge itself).
    const std::vector<RoomGeometry::Mirror> faces_in_room = geometry_.mirrors();
    for (size_t w = 0; w < faces_in_room.size() && kFaces + kSecondOrder + int(w) < kEchoes; ++w) {
        const RoomGeometry::Mirror& m = faces_in_room[w];
        const auto before = [&](Vec3 p) { return (p.x - m.centre.x) * m.normal.x + (p.z - m.centre.z) * m.normal.z; };
        const float source_side = before(s.position), place_side = before(at);
        if (source_side <= 0.01f || place_side <= 0.01f) continue;
        Bounce& b = out[size_t(kFaces + kSecondOrder) + w];
        b.image = {s.position.x - 2.0f * source_side * m.normal.x, s.position.y, s.position.z - 2.0f * source_side * m.normal.z};
        const float t = place_side / (place_side + source_side);
        const Vec3 strike{at.x + (b.image.x - at.x) * t, at.y + (b.image.y - at.y) * t, at.z + (b.image.z - at.z) * t};
        const float along = (strike.x - m.centre.x) * m.along.x + (strike.z - m.centre.z) * m.along.z;
        const float inside = std::min(m.half_length - std::fabs(along), m.top - strike.y);
        const float edge = std::clamp(0.5f + inside / 0.6f, 0.0f, 1.0f);
        if (edge <= 0.0f) continue;
        const Vec3 off{strike.x + m.normal.x * 0.01f, strike.y, strike.z + m.normal.z * 0.01f};  // (not through itself)
        const std::array<float, 3> kept = through({s.position, off, at}), as_mirror = specular(m.material), spread = scattered(m.material);
        for (size_t k = 0; k < 3; ++k) {
            b.mirror[k] = as_mirror[k] * edge * kept[k];
            b.scatter[k] = spread[k] * edge * kept[k];
        }
        b.gain = 1.0f;
        beaming(b, mirroredAcross(s.radiator, m.centre, m.normal));
        b.bus = kFaces + int(w / 2);
        b.on = true;
    }
}

// A source's reflections, as the listener hears them (see bounces): told to the audio thread, which works out its
// distance and the way it comes from as the listener glides. Those that aren't (and weren't) heard aren't told.
void AudioEngine::updateEchoes(Source& s) {
    if (!inRoom(s.kind)) return;
    std::array<Bounce, kEchoes> all;
    bounces(s, ear_, all);
    for (int k = 0; k < kEchoes; ++k) {
        const Bounce& b = all[size_t(k)];
        if (!b.on && !s.echo_sent[size_t(k)]) continue;
        s.echo_sent[size_t(k)] = b.on;
        Command c; c.type = Command::Echo; c.id = s.id; c.v[8] = float(k); c.count = b.bus;
        c.at[0] = s.position.x;
        c.at[1] = s.position.y;
        c.at[2] = s.position.z;
        c.v[0] = b.image.x;
        c.v[1] = b.image.y;
        c.v[2] = b.image.z;
        c.v[3] = b.on ? b.gain : 0.0f;
        c.v[4] = b.cut_hz;
        for (size_t band = 0; band < 3; ++band) {
            c.v[5 + band] = b.mirror[band];
            c.scatter[band] = b.scatter[band];
        }
        push(c);
    }
}

void AudioEngine::setRoom(float width, float height, float depth, const std::vector<Wall>& walls, const RoomSurfaces& surfaces) {
    const float room[3] = {std::clamp(width, 2.0f, 100.0f), std::clamp(height, 2.0f, 50.0f), std::clamp(depth, 2.0f, 100.0f)};
    geometry_.setRoom(room[0], room[2], room[1], walls);
    std::copy(room, room + 3, room_dims_.begin());
    for (int w = 0; w < RoomGeometry::kMaxWalls; ++w) {  // (where each wall's scattered sound comes from)
        Command c; c.type = Command::ScatterWall; c.id = w;
        if (w < int(walls.size())) {
            c.v[0] = walls[size_t(w)].ax;
            c.v[1] = walls[size_t(w)].az;
            c.v[2] = walls[size_t(w)].bx;
            c.v[3] = walls[size_t(w)].bz;
            c.v[4] = std::min(walls[size_t(w)].height, room[1]);
            c.v[5] = 1.0f;
        }
        push(c);
    }
    surfaces_ = surfaces;
    updatePaths();
    for (auto& s : owned_)
        if (s && !s->removing && isMic(s->kind)) updateMicPaths(*s);
    // How long it rings in each band, from what its surfaces (and the walls standing in it, both faces) absorb and what
    // the air takes; how loud, from its room constant (the more it absorbs, the quieter its ring); and its delay lines
    // as long as its average distance between bounces (volume over surface) has them.
    std::vector<StandingSurface> standing;
    for (const Wall& w : walls)
        standing.push_back({std::hypot(w.bx - w.ax, w.bz - w.az) * std::min(w.height, room[1]), w.material});
    const RoomAcoustics acoustics = roomAcoustics(room[0], room[1], room[2], surfaces, standing);
    wanted_size_ = (volumeOf(room) / surfaceOf(room)) / (volumeOf(kReferenceRoom) / surfaceOf(kReferenceRoom));
    wanted_rt60_ = acoustics.decay;
    wanted_level_ = kReverbLevel * std::sqrt(referenceAcoustics().constant / std::max(acoustics.constant, 0.1f));
    roomSettled();
}

void AudioEngine::setEarlyReflections(bool on) {
    early_reflections_ = on;
    updatePaths();
    for (auto& s : owned_)
        if (s && !s->removing && isMic(s->kind)) updateMicPaths(*s);
}

bool AudioEngine::roomSettled() {
    const bool fading = reverb_changing_.load(std::memory_order_acquire);
    if (wanted_rt60_ == room_rt60_ && wanted_size_ == room_size_ && wanted_level_ == room_level_) return !fading;  // (as it is)
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
                                      bool blocked, const float* through) {
    Command c; c.type = Command::SourceDirectPath; c.id = id;
    c.v[0] = via.x; c.v[1] = via.y; c.v[2] = via.z;
    c.v[3] = std::max(extra_length, 0.0f);
    directPathGains(path_differences, count, blocked, &c.v[4], through);
    push(c);
}
void AudioEngine::setSourceMuted(int id, bool muted) {
    Command c; c.type = Command::SourceMuted; c.id = id; c.v[0] = muted ? 1.0f : 0.0f; push(c);
}
void AudioEngine::setSourceSoloMuted(int id, bool silenced) {
    Command c; c.type = Command::SourceSoloMuted; c.id = id; c.v[0] = silenced ? 1.0f : 0.0f; push(c);
}
void AudioEngine::setSourceOutput(int id, int bus) {
    const Source* target = bus >= 0 ? owned(bus) : nullptr;
    if (bus >= 0 && (!target || !isBus(target->kind) || bus == id)) bus = -1;  // (no bus into itself; folders in folders, though)
    Command c; c.type = Command::SourceOutput; c.id = id; c.v[0] = float(bus); push(c);
    if (Source* s = owned(id)) s->route = bus;
    updateDelayCompensation();
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
    reapPedals();   // and to free pedals taken off a board
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
void AudioEngine::setReverb(bool on) { setReverbLevel(on ? 1.0f : 0.0f); }
void AudioEngine::setReverbLevel(float gain) {
    Command c; c.type = Command::Reverb; c.v[0] = std::clamp(gain, 0.0f, 4.0f); push(c);
}
void AudioEngine::setMasterVolume(float gain) {
    Command c; c.type = Command::MasterVolume; c.v[0] = std::clamp(gain, 0.0f, 4.0f); push(c);
}
void AudioEngine::setRoomVolume(float gain) {
    Command c; c.type = Command::RoomVolume; c.v[0] = std::clamp(gain, 0.0f, 4.0f); push(c);
}
void AudioEngine::setMonitor(Monitor monitor) {
    Command c; c.type = Command::MonitorSet; c.v[0] = monitor == Monitor::Mix ? 1.0f : 0.0f; push(c);
    heard_ = monitor;
}
void AudioEngine::setMasterOutput(int left, int right, Monitor which) {
    (which == Monitor::Mix ? mix_out_left_ : room_out_left_).store(left, std::memory_order_relaxed);
    (which == Monitor::Mix ? mix_out_right_ : room_out_right_).store(right, std::memory_order_relaxed);
}
void AudioEngine::setMasterInserts(int bus, Monitor which) {
    const Source* s = bus >= 0 ? owned(bus) : nullptr;
    Command c; c.type = Command::MasterInserts; c.id = s && isBus(s->kind) ? bus : -1; c.v[0] = float(which); push(c);
    master_bus_wanted_[size_t(which)] = c.id;
    updateDelayCompensation();
}
void AudioEngine::setSourceRoomGain(int id, float gain) {
    Command c; c.type = Command::SourceRoomGain; c.id = id; c.v[0] = std::clamp(gain, 0.0f, 100.0f); push(c);
}
void AudioEngine::setSourceRoomMuted(int id, bool muted) {
    Command c; c.type = Command::SourceRoomMuted; c.id = id; c.v[0] = muted ? 1.0f : 0.0f; push(c);
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
    setMasterLimiter(on, Monitor::Mix);
    setMasterLimiter(on, Monitor::Room);
}
void AudioEngine::setMasterLimiter(bool on, Monitor which) {
    Command c; c.type = Command::LimiterOn; c.v[0] = on ? 1.0f : 0.0f; c.v[1] = float(which); push(c);
}

void AudioEngine::setLimiterCeiling(float db) {
    Command c; c.type = Command::LimiterCeiling; c.v[0] = std::pow(10.0f, std::clamp(db, -20.0f, 0.0f) / 20.0f); push(c);
}

// ── Delay compensation ──────────────────────────────────────────────────────────────────────────────────────

namespace {

// How late a pedal's plug-in makes what it plays back, as it reports it (a stock pedal's: none). Told to the pedal,
// for its bypass.
int pedalDelay(Pedal* pedal) {
    if (!pedal || pedal->kind() != PedalKind::Plugin) return 0;
    auto* holder = static_cast<PluginPedal*>(pedal);
    const int samples = holder->ready() && holder->plugin() ? std::max(holder->plugin()->latencySamples(), 0) : 0;
    pedal->setLatency(samples);
    return samples;
}

}  // namespace

int AudioEngine::ownDelay(Source& s) {
    int delay = 0;
    for (auto& slot : s.inserts) delay += pedalDelay(slot.pedal.get());
    if (s.synth.pedal) {  // a plug-in instrument's own
        auto* holder = static_cast<PluginPedal*>(s.synth.pedal.get());
        delay += holder->ready() && holder->plugin() ? std::max(holder->plugin()->latencySamples(), 0) : 0;
    }
    if (isAmp(s.kind)) {  // its pedals: those in front, and those in its loop (the preamp's signal held back to meet them)
        const int front = int(s.pedals.size()) - std::clamp(s.fx_loop, 0, int(s.pedals.size()));
        int loop = 0;
        for (int p = 0; p < int(s.pedals.size()); ++p) {
            const int d = pedalDelay(s.pedals[size_t(p)].pedal.get());
            if (p < front) delay += d;
            else loop += d;
        }
        loop = std::min(loop, kMaxCompensation);
        if (loop != s.loop_delay) {
            s.loop_delay = loop;
            Command c; c.type = Command::AmpLoopDelay; c.id = s.id; c.v[0] = float(loop); push(c);
        }
        delay += loop;
    }
    return delay;
}

// Each track's delay (its plug-ins'), and when its sound leaves it (before it is held back): a track's at once, a bus's
// once the latest of what plays or sends into it has arrived, and its own plug-ins have played. Each is then held
// back to meet the latest of the others where it goes (its folder, or the mix's master), and each send to meet the
// rest at its aux. The masters' buses aren't part of it: what reaches them is lined up already.
void AudioEngine::updateDelayCompensation() {
    const int n = int(owned_.size());
    std::vector<int> own(size_t(n), 0), leaves(size_t(n), 0), arrives(size_t(n), 0);
    std::vector<bool> counted(size_t(n), false);
    for (int id = 0; id < n; ++id) {
        Source* s = owned(id);
        if (!s) continue;
        own[size_t(id)] = ownDelay(*s);
        counted[size_t(id)] = !(isBus(s->kind) && (id == master_bus_wanted_[0] || id == master_bus_wanted_[1]));
        leaves[size_t(id)] = own[size_t(id)];
    }
    auto into = [&](int bus) { return bus >= 0 && bus < n && counted[size_t(bus)] && owned(bus) && isBus(owned(bus)->kind); };
    // A bus fed by a bus is worked out after it: as many rounds as it takes (a circle, which the game never makes, is
    // cut short by the rounds running out).
    for (int round = 0; round <= kSourceSlots; ++round) {
        std::vector<int> latest(size_t(n), 0);
        for (int id = 0; id < n; ++id) {
            Source* s = owned(id);
            if (!s || !counted[size_t(id)]) continue;
            if (into(s->route)) latest[size_t(s->route)] = std::max(latest[size_t(s->route)], leaves[size_t(id)]);
            for (int to : s->send_to)
                if (into(to)) latest[size_t(to)] = std::max(latest[size_t(to)], leaves[size_t(id)]);
        }
        bool settled = true;
        for (int id = 0; id < n; ++id) {
            Source* s = owned(id);
            if (!s || !counted[size_t(id)] || !isBus(s->kind)) continue;
            const int now = std::min(latest[size_t(id)] + own[size_t(id)], 4 * kMaxCompensation);
            arrives[size_t(id)] = latest[size_t(id)];
            if (now != leaves[size_t(id)]) {
                leaves[size_t(id)] = now;
                settled = false;
            }
        }
        if (settled) break;
    }
    int total = 0;
    for (int id = 0; id < n; ++id) {
        Source* s = owned(id);
        if (s && counted[size_t(id)] && !into(s->route)) total = std::max(total, leaves[size_t(id)]);
    }
    const auto held = [&](int until, int leaving, bool& over) {
        const int by = std::max(until - leaving, 0);
        over = over || by > kMaxCompensation;
        return compensation_on_ ? std::min(by, kMaxCompensation) : 0;
    };
    for (int id = 0; id < n; ++id) {
        Source* s = owned(id);
        if (!s) continue;
        TrackDelay delay;
        delay.delay = own[size_t(id)];
        std::array<int, kMaxSends> sends{};
        if (counted[size_t(id)]) {
            delay.compensation = held(into(s->route) ? arrives[size_t(s->route)] : total, leaves[size_t(id)], delay.over);
            for (int k = 0; k < kMaxSends; ++k)
                if (into(s->send_to[size_t(k)])) sends[size_t(k)] = held(arrives[size_t(s->send_to[size_t(k)])], leaves[size_t(id)], delay.over);
        }
        const bool changed = delay.compensation != s->delay.compensation || sends != s->send_compensation;
        s->delay = delay;
        s->send_compensation = sends;
        if (!changed) continue;
        Command c; c.type = Command::Compensation; c.id = id;
        for (size_t k = 0; k < s->holds.size(); ++k) {
            const int by = k == 0 ? delay.compensation : sends[k - 1];
            if (by > 0 && !s->holds[k]) s->holds[k] = std::make_unique<CompensationDelay>();  // (kept from now on)
            c.lines[k] = s->holds[k].get();
            c.v[k] = float(by);
        }
        push(c);
    }
    total = compensation_on_ ? std::min(total, kMaxCompensation) : 0;
    if (total != compensation_total_) {
        compensation_total_ = total;
        Command c; c.type = Command::CompensationTotal; c.v[0] = float(total); push(c);
    }
}

void AudioEngine::setDelayCompensation(bool on) {
    compensation_on_ = on;
    updateDelayCompensation();
}

void AudioEngine::refreshDelayCompensation() { updateDelayCompensation(); }

bool AudioEngine::hasSource(int id) const { return owned(id) != nullptr; }

AudioEngine::TrackDelay AudioEngine::trackDelay(int id) const {
    const Source* s = owned(id);
    return s ? s->delay : TrackDelay{};
}

// Its sound on its way to where it plays (its folder, or the mix's master), held back by its delay compensation: once
// it has a delay line, all of it goes through (with none to make up, at once), so that a delay taken up later has
// what came before.
void AudioEngine::playOut(Source& s, const float* l, const float* r, float* to_l, float* to_r) {
    if (CompensationDelay* hold = s.holds_rt[0]) {
        std::copy(l, l + block_, comp_l_.begin());
        std::copy(r, r + block_, comp_r_.begin());
        hold->process(comp_l_.data(), comp_r_.data(), block_, s.held_by[0]);
        l = comp_l_.data();
        r = comp_r_.data();
    }
    for (int i = 0; i < block_; ++i) {
        to_l[i] += l[i];
        to_r[i] += r[i];
    }
}

// One of its sends: `l` and `r`, scaled, into the aux at its level (glided), held back by its own compensation.
void AudioEngine::playSend(Source& s, int slot, Source& aux, const float* l, const float* r, float scale, float mute_coef) {
    auto& send = s.sends[size_t(slot)];
    const float target = send.on ? send.gain_target : 0.0f;
    if (CompensationDelay* hold = s.holds_rt[size_t(1 + slot)]) {
        for (int i = 0; i < block_; ++i) {
            comp_l_[size_t(i)] = l[i] * scale;
            comp_r_[size_t(i)] = r[i] * scale;
        }
        hold->process(comp_l_.data(), comp_r_.data(), block_, s.held_by[size_t(1 + slot)]);
        l = comp_l_.data();
        r = comp_r_.data();
        scale = 1.0f;
    }
    for (int i = 0; i < block_; ++i) {
        send.gain += (target - send.gain) * mute_coef;
        aux.bus_l[size_t(i)] += l[i] * scale * send.gain;
        aux.bus_r[size_t(i)] += r[i] * scale * send.gain;
    }
}

MeterReading AudioEngine::readMeter() {
    MeterReading m;
    m.peak_l = meter_peak_l_.exchange(0.0f, std::memory_order_relaxed);
    m.peak_r = meter_peak_r_.exchange(0.0f, std::memory_order_relaxed);
    m.rms_l = meter_rms_l_.load(std::memory_order_relaxed);
    m.rms_r = meter_rms_r_.load(std::memory_order_relaxed);
    m.limiter_gain = meter_gain_.exchange(1.0f, std::memory_order_relaxed);
    m.clipped = meter_clipped_.exchange(0, std::memory_order_relaxed);
    m.reverb_peak_l = reverb_peak_l_.exchange(0.0f, std::memory_order_relaxed);
    m.reverb_peak_r = reverb_peak_r_.exchange(0.0f, std::memory_order_relaxed);
    m.reverb_rms_l = reverb_rms_l_.load(std::memory_order_relaxed);
    m.reverb_rms_r = reverb_rms_r_.load(std::memory_order_relaxed);
    m.room_peak_l = room_peak_l_.exchange(0.0f, std::memory_order_relaxed);
    m.room_peak_r = room_peak_r_.exchange(0.0f, std::memory_order_relaxed);
    m.room_rms_l = room_rms_l_.load(std::memory_order_relaxed);
    m.room_rms_r = room_rms_r_.load(std::memory_order_relaxed);
    m.mix_peak_l = mix_peak_l_.exchange(0.0f, std::memory_order_relaxed);
    m.mix_peak_r = mix_peak_r_.exchange(0.0f, std::memory_order_relaxed);
    m.mix_rms_l = mix_rms_l_.load(std::memory_order_relaxed);
    m.mix_rms_r = mix_rms_r_.load(std::memory_order_relaxed);
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

float AudioEngine::sourceLevel(int id, bool pre_fader) const {
    if (id < 0 || id >= kSourceSlots) return 0.0f;
    return (pre_fader ? pre_levels_ : levels_)[size_t(id)].load(std::memory_order_relaxed);
}

float AudioEngine::sourcePeak(int id, bool pre_fader) {
    if (id < 0 || id >= kSourceSlots) return 0.0f;
    return (pre_fader ? pre_peaks_ : peaks_)[size_t(id)].exchange(0.0f, std::memory_order_relaxed);
}

float AudioEngine::sourceRoomLevel(int id) const {
    return id < 0 || id >= kSourceSlots ? 0.0f : room_levels_[size_t(id)].load(std::memory_order_relaxed);
}

float AudioEngine::sourceRoomPeak(int id) {
    return id < 0 || id >= kSourceSlots ? 0.0f : room_peaks_[size_t(id)].exchange(0.0f, std::memory_order_relaxed);
}

EngineStats AudioEngine::stats() const {
    EngineStats s = device_stats_;
    if (!s.device_running) {
        s.sample_rate = sr_;
        s.block_size = block_;
    }
    // The binaural rendering's delay is the engine's own, not the device's: it comes and goes with the setting.
    s.binaural_ms = binaural_wanted_ ? 1000.0 * steam_.binauralDelay() / sr_ : 0.0;
    s.compensation_ms = 1000.0 * compensation_total_ / sr_;
    // (what is heard: the room, after its binaural rendering; the mix, held back by its delay compensation)
    s.output_latency_ms = s.buffer_ms + s.device_ms + (heard_ == Monitor::Mix ? s.compensation_ms : s.binaural_ms);
    s.cpu_load = cpu_load_.load(std::memory_order_relaxed);
    s.blocks = blocks_.load(std::memory_order_relaxed);
    s.disk_misses = streamer_.misses();
    s.disk_mb = double(streamer_.bytesInMemory()) / double(1 << 20);
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
                for (Source* mic : sources_)  // (heard afresh, once the way it comes is known)
                    if (mic)
                        for (int k = 0; k < mic->capsule_count; ++k) (*mic->capsules[size_t(k)].pickups)[size_t(c.id)] = {};
                break;
            case Command::SourceSoloMuted:
                if (s) s->solo_target = c.v[0] > 0.5f ? 0.0f : 1.0f;
                break;
            case Command::MicPath:
                if (s && int(c.v[8]) < s->capsule_count && c.v[0] >= 0.0f && int(c.v[0]) < kSourceSlots) {
                    Source::Pickup& k = (*s->capsules[size_t(c.v[8])].pickups)[size_t(c.v[0])];
                    k.target = std::max(c.v[1], 0.0f);
                    for (int b = 0; b < 3; ++b) k.band_target[b] = c.v[2 + b];
                    k.from_target = {c.v[5], c.v[6], c.v[7]};
                }
                break;
            case Command::MicCone: {  // (epoch: the source, the capsule, which way, how many ways it has, whose scattered sound, and
                                      // whether it is a reflection)
                const int source = int(c.epoch & 0x3F), capsule = int((c.epoch >> 6) & 0x1);
                const int at = int((c.epoch >> 7) & 0x7F), ways = int((c.epoch >> 14) & 0x7F), surface = int((c.epoch >> 21) & 0x1F);
                if (!s || capsule >= s->capsule_count || source >= kSourceSlots) break;
                Source::Pickup& k = (*s->capsules[size_t(capsule)].pickups)[size_t(source)];
                if (k.ways != std::min(ways, kMaxWays))  // a cabinet set up afresh, or the floor: each way heard anew
                    for (auto& w : k.way) w = {};
                k.ways = std::min(ways, kMaxWays);
                if (at >= k.ways) break;
                Source::Pickup::Way& w = k.way[size_t(at)];
                w.filtered = c.v[3] > 0.0f;
                w.reflection = (c.epoch >> 26) & 0x1;
                w.distance_target = c.v[0];
                w.nearness_target = c.v[1];
                w.gain_target = c.v[2];
                w.cut_target = std::max(c.v[3], 20.0f);
                w.low_target = c.v[4];
                w.high_target = c.v[5];
                w.from_target = {c.v[6], c.v[7], c.v[8]};
                std::copy(c.bands, c.bands + 3, w.bands_target);
                std::copy(c.scatter, c.scatter + 3, w.scatter_target);
                w.surface = surface < kScatterBuses ? surface : -1;
                if (w.distance < 0.0f) {  // new: from where it is
                    w.distance = w.distance_target;
                    w.nearness = w.nearness_target;
                    w.gain = w.gain_target;
                    w.cut = w.cut_target;
                    w.low_db = w.low_target;
                    w.high_db = w.high_target;
                    w.from = w.from_target;
                    std::copy(w.bands_target, w.bands_target + 3, w.bands);
                    std::copy(w.scatter_target, w.scatter_target + 3, w.scatter);
                }
                break;
            }
            case Command::SourceFacing:
                if (s) {
                    s->facing = c.v[0] > 0.0f;
                    s->facing_cut_target = std::max(c.v[0], 20.0f);
                    s->facing_gain_target = c.v[1];
                    s->power_cut = c.v[2];
                    s->cone_radius = c.v[3];
                }
                break;
            case Command::MicModelSet:
                if (s && isMic(s->kind))
                    for (int k = 0; k < s->capsule_count; ++k)
                        if (int(c.v[2]) < 0 || int(c.v[2]) == k) soundAs(*s, k, int(c.v[0]), int(c.v[1]));
                break;
            case Command::MicAim:
                if (s && int(c.v[3]) < s->capsule_count) s->capsules[size_t(c.v[3])].aim_target = {c.v[0], c.v[1], c.v[2]};
                break;
            case Command::MicMidSide:
                if (s) {
                    s->mid_side = c.v[0] > 0.5f;
                    s->width_target = c.v[1];
                }
                break;
            case Command::SourcePan:
                if (s) s->pan_target = c.v[0];
                break;
            case Command::BusMono:
                if (s) s->bus_mono = c.v[0] > 0.5f;
                break;
            case Command::Compensation:
                if (s)
                    for (size_t k = 0; k < s->holds_rt.size(); ++k) {
                        s->holds_rt[k] = c.lines[k];
                        s->held_by[k] = int(c.v[k]);
                    }
                break;
            case Command::CompensationTotal:
                click_compensation_ = int(c.v[0]);
                break;
            case Command::Echo:  // (v[8]: which of its reflections; count: whose scattered sound it adds to)
                if (s && c.v[8] >= 0.0f && int(c.v[8]) < kEchoes) {
                    Source::Echo& e = s->echoes[size_t(c.v[8])];
                    e.bus = std::clamp(int(c.count), 0, kScatterBuses - 1);
                    e.second = int(c.v[8]) >= kFaces && int(c.v[8]) < kFaces + kSecondOrder;
                    e.image = {c.v[0], c.v[1], c.v[2]};
                    e.source = {c.at[0], c.at[1], c.at[2]};
                    e.gain_target = c.v[3];
                    e.filtered = c.v[4] > 0.0f;
                    e.cut_target = std::max(c.v[4], 20.0f);
                    for (size_t b = 0; b < 3; ++b) {
                        e.mirror_target[b] = c.v[5 + b];
                        e.scatter_target[b] = c.scatter[b];
                    }
                    if (e.late < 0.0f) {  // not heard yet: from where it is
                        e.gain = e.gain_target;
                        e.cut = e.cut_target;
                        e.mirror = e.mirror_target;
                        e.scatter = e.scatter_target;
                    }
                }
                break;
            case Command::ScatterWall:
                if (c.id >= 0 && c.id < RoomGeometry::kMaxWalls) {
                    std::copy(c.v, c.v + 5, scatter_walls_[size_t(c.id)].begin());
                    scatter_wall_on_[size_t(c.id)] = c.v[5] > 0.5f;
                }
                break;
            case Command::AmpLoopDelay:
                if (s && isAmp(s->kind)) static_cast<Amp*>(s->instrument.get())->setLoopDelay(int(c.v[0]));
                break;
            case Command::RemoveSource:
                if (s) {  // fade it out first, so it doesn't leave with a click
                    s->mute_target = 0.0f;
                    s->room_mute_target = 0.0f;
                    s->loop = false;
                    s->fade_blocks = int(0.06f * float(sr_) / float(block_)) + 1;
                }
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
                if (s && s->armed && playsNotes(s->kind) && punchedIn())
                    captured_.push({s->id, int(c.v[0]), c.v[1], true, recordedSteps()});
                break;
            case Command::NoteOff:
                if (s) s->instrument->noteOff(int(c.v[0]));
                if (s && recording_ && s->armed && playsNotes(s->kind) && clock_ >= punch_clock_)
                    captured_.push({s->id, int(c.v[0]), 0.0f, false, recordedSteps()});
                break;
            case Command::TimelinePlay:
                for (Source* each : sources_)
                    if (each) each->instrument->stopSequenced();
                sequencer_.start(clock_, double(c.v[0]));
                chaseSustain(double(c.v[0]));
                streamer_.reached(c.epoch);
                break;
            case Command::TimelineLoop:
                sequencer_.setLoop(c.v[0] > 0.5f, double(c.v[1]), double(c.v[2]));
                break;
            case Command::TrackSet:
                if (s) {
                    s->track_rt = static_cast<Source::Track*>(c.data);
                    s->board_applied.store(c.epoch, std::memory_order_release);
                }
                break;
            case Command::SourceOutput:
                if (s) s->output = int(c.v[0]);
                break;
            case Command::SendSet:
                if (s) {
                    auto& send = s->sends[size_t(int(c.v[0]))];
                    send.bus = int(c.v[1]);
                    send.gain_target = c.v[2];
                    send.pre = c.v[3] > 0.5f;
                    send.on = c.v[4] > 0.5f;
                }
                break;
            case Command::MasterAutomation:
                master_auto_rt_[size_t(c.v[0])] = static_cast<std::vector<AutoPoint>*>(c.data);
                master_applied_[size_t(c.v[0])].store(c.epoch, std::memory_order_release);
                break;
            case Command::MasterRead:
                master_read_[size_t(c.v[1])] = c.v[0] > 0.5f;
                break;
            case Command::AutomationRead:
                if (s) {
                    s->read_volume = c.v[0] > 0.5f;
                    s->read_mute = c.v[1] > 0.5f;
                    s->read_sustain = c.v[2] > 0.5f;
                    s->read_params = c.v[3] > 0.5f;
                    if (!s->read_sustain && s->auto_sustain) {
                        s->auto_sustain = false;
                        s->instrument->sustain(false);
                    }
                }
                break;
            case Command::RecordArm:
                if (s) {
                    s->armed = c.v[0] > 0.5f;
                    if (!s->armed && !s->input_on) s->instrument->allNotesOff();  // (an armed instrument takes notes too)
                }
                break;
            case Command::RecordStart: {
                count_in_end_ = 0;
                punch_clock_ = clock_;
                punch_out_clock_ = INT64_MAX;
                punch_out_step_ = -1.0;
                double from = sequencer_.position(clock_);
                const double punch_in = double(c.v[0]), punch_out = double(c.v[4]);
                if (!sequencer_.running()) {
                    for (Source* each : sources_)
                        if (each) each->instrument->stopSequenced();
                    // A count-in: the timeline starts once the click has counted it (whole beats, at least one).
                    const int beats = c.v[1] > 0.0f ? std::max(1, int(std::lround(c.v[1] / 4.0f))) : 0;
                    const double beat_samples = 4.0 * sequencer_.stepSamples();
                    // The music from the pre-roll's start (after the count-in, if there is one); the recording from the step
                    // asked for, and to the punch out.
                    const double play_from = std::max(punch_in - double(c.v[3]), 0.0);
                    sequencer_.start(clock_ + int64_t(std::llround(beats * beat_samples)), play_from);
                    chaseSustain(play_from);
                    if (beats > 0) {
                        count_in_end_ = int64_t(std::llround(sequencer_.timeOfStep(play_from)));
                        count_in_beats_ = beats;
                        count_in_beat_samples_ = beat_samples;
                    }
                    punch_clock_ = int64_t(std::llround(sequencer_.timeOfStep(punch_in)));
                    from = punch_in;
                    if (punch_out > punch_in) {
                        punch_out_clock_ = int64_t(std::llround(sequencer_.timeOfStep(punch_out)));
                        punch_out_step_ = punch_out;
                    }
                } else if (punch_out > from) {  // already playing: from here, to the punch out
                    punch_out_clock_ = clock_ + int64_t(std::llround((punch_out - from) * sequencer_.stepSamples()));
                    punch_out_step_ = punch_out;
                }
                sequencer_.suspendLoop(c.v[2] < 0.5f);  // round the loop only when loop recording
                recorder_rt_ = static_cast<Recorder*>(c.data);
                recording_ = true;
                record_start_.store(from);
                record_step_seconds_.store(sequencer_.stepSamples() / sr_);
                break;
            }
            case Command::RecordStop:
                if (recording_)
                    record_end_.store(std::max(punch_out_step_ >= 0.0 ? std::min(recordedSteps(), punch_out_step_) : recordedSteps(), record_start_.load()));
                recording_ = false;
                count_in_end_ = 0;
                recorder_rt_ = nullptr;
                sequencer_.suspendLoop(false);
                record_ack_.store(c.epoch, std::memory_order_release);
                break;
            case Command::AllNotesOff:
                if (s) s->instrument->allNotesOff();
                break;
            case Command::Binaural:
                binaural_ = c.v[0] > 0.5f;
                if (clock_ == 0) binaural_mix_ = binaural_ ? 1.0f : 0.0f;  // set before anything has played: nothing to fade from
                break;
            case Command::Reverb:
                reverb_target_ = c.v[0];
                break;
            case Command::MasterVolume:
                master_target_ = c.v[0];
                if (clock_ == 0) master_gain_ = master_target_;  // set before anything has played: nothing to glide from
                break;
            case Command::RoomVolume:
                room_target_ = c.v[0];
                if (clock_ == 0) room_volume_ = room_target_;
                break;
            case Command::MonitorSet:
                monitor_ = c.v[0] > 0.5f ? Monitor::Mix : Monitor::Room;
                break;
            case Command::MasterInserts: {  // (the last bus marked is no longer the master's: played as a bus again)
                int& bus = master_bus_[size_t(c.v[0])];
                if (bus >= 0 && sources_[size_t(bus)]) sources_[size_t(bus)]->master_role = 0;
                bus = c.id;
                if (bus >= 0 && sources_[size_t(bus)]) sources_[size_t(bus)]->master_role = 1 + int(c.v[0]);
                break;
            }
            case Command::SourceRoomGain:
                if (s) s->room_gain_target = c.v[0];
                break;
            case Command::SourceRoomMuted:
                if (s) s->room_mute_target = c.v[0] > 0.5f ? 0.0f : 1.0f;
                break;
            case Command::SourceInput:
                if (s) {
                    s->input_on = c.v[0] > 0.5f;
                    s->instrument->setInputEnabled(s->input_on);
                    // Notes held when the input goes off would never get their note-off: let them go now.
                    if (!s->input_on) s->instrument->allNotesOff();
                }
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
                    sequencer_.stop(clock_);
                    step_.store(-1, std::memory_order_relaxed);
                    for (Source* each : sources_) {
                        if (!each) continue;
                        each->instrument->stopSequenced();
                        if (each->auto_sustain) {  // the pedal its automation held down, let up
                            each->auto_sustain = false;
                            each->instrument->sustain(false);
                        }
                    }
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
            case Command::AmpHeadSet:
                if (s && isAmp(s->kind)) static_cast<Amp*>(s->instrument.get())->setHead(AmpHead(int(c.v[0])), c.v[1] > 0.5f);
                break;
            case Command::AmpCabinetSet:
                if (s && isAmp(s->kind)) static_cast<Amp*>(s->instrument.get())->setCabinet(AmpCabinet(int(c.v[0])), c.v[1] > 0.5f);
                break;
            case Command::AmpSpeakerSet:
                if (s && isAmp(s->kind)) static_cast<Amp*>(s->instrument.get())->setSpeaker(AmpSpeaker(int(c.v[0])));
                break;
            case Command::AmpLoopMix:
                if (s && isAmp(s->kind)) static_cast<Amp*>(s->instrument.get())->setLoopMix(c.v[0]);
                break;
            case Command::AmpKnob:
                if (s && isAmp(s->kind)) static_cast<Amp*>(s->instrument.get())->setControl(AmpControl(int(c.v[0])), c.v[1]);
                break;
            case Command::LooperMemory:
                if (s) static_cast<LooperPedal*>(c.pedals[0])->looper().setMemory(c.memory[0], c.memory[1], c.count);
                break;
            case Command::LooperAct:
                if (s) static_cast<LooperPedal*>(c.pedals[0])->looper().act(Looper::Action(int(c.v[0])));
                break;
            case Command::PedalBoardSet:
                if (s) {
                    PedalBoard& board = c.v[0] > 0.5f ? s->insert_board : s->board;
                    for (int i = 0; i < int(c.count); ++i) {
                        board.pedals[size_t(i)] = c.pedals[i];
                        board.slots[size_t(i)] = c.slots[i];
                    }
                    board.count = int(c.count);
                    board.front = c.v[0] > 0.5f ? board.count : int(c.v[1]);
                    s->board_applied.store(c.epoch, std::memory_order_release);  // the pedals it left out may now be freed
                }
                break;
            case Command::PedalOn:
                if (s) c.pedals[0]->setOn(c.v[0] > 0.5f);
                break;
            case Command::SynthPlugin:
                if (s && s->kind == InstrumentKind::PluginSynth) {
                    auto* holder = static_cast<PluginPedal*>(c.pedals[0]);
                    static_cast<PluginSynth*>(s->instrument.get())->setPlugin(holder && holder->ready() ? holder->plugin() : nullptr);
                    s->board_applied.store(c.epoch, std::memory_order_release);  // the one it held may now be freed
                }
                break;
            case Command::PedalControl:
                if (s) c.pedals[0]->setControl(int(c.v[0]), c.v[1]);
                break;
            case Command::SourceGain:
                if (s) s->gain_target = c.v[0];
                break;
            case Command::SourceVolume:
                if (s) s->volume_target = c.v[0];
                break;
            case Command::Falloff:
                falloff_target_ = c.v[0];
                if (clock_ == 0) falloff_ = falloff_target_;  // set before anything has played: nothing to glide from
                break;
            case Command::LimiterOn:
                limiter_on_[size_t(c.v[1])] = c.v[0] > 0.5f;
                break;
            case Command::LimiterCeiling:
                limiter_.setCeiling(c.v[0]);
                room_limiter_.setCeiling(c.v[0]);
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
        for (Source* s : sources_) {  // every instrument with its input on, or armed for recording (as Pro Tools' MIDI thru)
            if (!s || !(s->input_on || s->armed) || !playsNotes(s->kind)) continue;
            const bool take = s->armed && punchedIn();
            switch (e.type) {
                case MidiEvent::NoteOn:
                    s->instrument->noteOn(e.note, e.velocity);
                    if (take) captured_.push({s->id, e.note, e.velocity, true, recordedSteps()});
                    break;
                case MidiEvent::NoteOff:
                    s->instrument->noteOff(e.note);
                    if (recording_ && s->armed && clock_ >= punch_clock_) captured_.push({s->id, e.note, 0.0f, false, recordedSteps()});
                    break;
                case MidiEvent::Sustain:
                    s->instrument->sustain(e.note != 0);
                    if (take) captured_.push({s->id, -1, 0.0f, e.note != 0, recordedSteps()});  // (note -1: the pedal)
                    break;
                case MidiEvent::Control: s->instrument->controlChange(e.note, e.value); break;
                case MidiEvent::PitchBend: s->instrument->pitchBend(e.bend); break;
            }
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
    const double straight = at - (index % 2 ? step_samples * sequencer_.swing() : 0.0);  // the step unswung
    for (Source* s : sources_) {
        if (!s) continue;
        if (s->track_rt && s->read_sustain && !s->track_rt->automation.sustain.empty() && playsNotes(s->kind)) {  // its pedal, as automated
            const auto& pedal = s->track_rt->automation.sustain;
            auto p = std::lower_bound(pedal.begin(), pedal.end(), double(index), [](const AutoPoint& a, double v) { return a.step < v; });
            for (; p != pedal.end() && p->step < double(index + 1); ++p) {
                s->auto_sustain = p->value > 0.5f;
                s->instrument->sustain(s->auto_sustain);
            }
        }
        if (s->track_rt && !s->track_rt->notes.empty() && playsNotes(s->kind)) {  // its recorded notes, to the sample
            const auto& notes = s->track_rt->notes;
            auto n = std::lower_bound(notes.begin(), notes.end(), double(index), [](const TimelineNote& a, double v) { return a.step < v; });
            for (; n != notes.end() && n->step < double(index + 1); ++n)
                s->instrument->play(n->note, n->length * step_sec, n->velocity, delayFor(straight + (n->step - double(index)) * step_samples));
        }
        if (!s->loop) continue;
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
    // Each master on outputs of its own too, if it has some the device has (and not the main ones).
    const auto own = [&](int a, int b) {
        return a >= 0 && b >= 0 && a < output_channels && b < output_channels && a != left && a != right && b != left && b != right;
    };
    const int mix_left = mix_out_left_.load(std::memory_order_relaxed), mix_right = mix_out_right_.load(std::memory_order_relaxed);
    const int room_left = room_out_left_.load(std::memory_order_relaxed), room_right = room_out_right_.load(std::memory_order_relaxed);
    const bool mix_too = own(mix_left, mix_right);
    const bool room_too = own(room_left, room_right) && !(mix_too && (room_left == mix_left || room_left == mix_right ||
                                                                       room_right == mix_left || room_right == mix_right));
    if (output_channels == 2 && left == 0 && right == 1 && !mix_too && !room_too) {
        render(input, input_channels, output, frames);
        return;
    }
    // Any other layout: render stereo in chunks, then place it on the chosen outputs and silence the rest.
    float stereo[2 * 256], mix[2 * 256], room[2 * 256];
    std::memset(output, 0, sizeof(float) * size_t(frames) * size_t(output_channels));
    for (int done = 0; done < frames;) {
        const int n = std::min(frames - done, 256);
        render(input ? input + size_t(done) * size_t(input_channels) : nullptr, input_channels, stereo, n, mix_too ? mix : nullptr,
               room_too ? room : nullptr);
        for (int i = 0; i < n; ++i) {
            float* frame = output + size_t(done + i) * size_t(output_channels);
            if (left == right) {
                frame[left] = 0.5f * (stereo[2 * i] + stereo[2 * i + 1]);  // a one-channel device gets a mono fold-down
            } else {
                frame[left] = stereo[2 * i];
                frame[right] = stereo[2 * i + 1];
            }
            if (mix_too) {
                frame[mix_left] = mix[2 * i];
                frame[mix_right] = mix[2 * i + 1];
            }
            if (room_too) {
                frame[room_left] = room[2 * i];
                frame[room_right] = room[2 * i + 1];
            }
        }
        done += n;
    }
}

void AudioEngine::render(const float* input, int input_channels, float* out, int frames, float* mix_out, float* room_out) {
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
            out[2 * (done + i)] = out_l_[size_t(block_pos_ + i)];
            out[2 * (done + i) + 1] = out_r_[size_t(block_pos_ + i)];
            if (mix_out) {
                mix_out[2 * (done + i)] = mix_tap_l_[size_t(block_pos_ + i)];
                mix_out[2 * (done + i) + 1] = mix_tap_r_[size_t(block_pos_ + i)];
            }
            if (room_out) {
                room_out[2 * (done + i)] = room_tap_l_[size_t(block_pos_ + i)];
                room_out[2 * (done + i) + 1] = room_tap_r_[size_t(block_pos_ + i)];
            }
        }
        block_pos_ += n;
        done += n;
    }
}

// Where each sample of this block falls on the timeline; each track's recorded audio for the block, ready to be played
// into it; and, while recording, what each armed Speaker and amp takes in, handed to the recorder (after a count-in,
// whose click is played here too).
void AudioEngine::renderTimeline() {
    const bool playing = sequencer_.running();
    const double step_seconds = sequencer_.stepSamples() / sr_;
    position_.store(sequencer_.position(clock_), std::memory_order_relaxed);
    streamer_.follow(sequencer_.position(clock_) * step_seconds, playing, sequencer_.looping(), sequencer_.loopStart() * step_seconds,
                     sequencer_.loopEnd() * step_seconds);  // (for the disk thread to read ahead of)
    for (int i = 0; i < block_; ++i) block_seconds_[size_t(i)] = playing ? sequencer_.position(clock_ + i) * step_seconds : -1.0;
    // A count-in's click: every beat before it ends, the first of each bar higher, whether the click is on or not.
    const int counting = count_in_end_ > clock_ ? int(std::min<int64_t>(count_in_end_ - clock_, block_)) : 0;  // its samples here
    count_in_left_.store(count_in_end_ > clock_ ? int(std::ceil(double(count_in_end_ - clock_) / count_in_beat_samples_ - 1e-6)) : 0,
                         std::memory_order_relaxed);
    if (counting > 0) {
        for (int beat = 0; beat < count_in_beats_; ++beat) {
            const int64_t at = count_in_end_ - int64_t(std::llround(double(count_in_beats_ - beat) * count_in_beat_samples_));
            if (at < clock_ || at >= clock_ + block_) continue;
            voice::ToneHit* free_click = &clicks_[0];
            for (auto& c : clicks_)
                if (!c.active) free_click = &c;
            const float pitch = beat % 4 == 0 ? 2000.0f : 1000.0f;
            free_click->start(float(sr_), int(at - clock_), false, pitch, pitch, 0.01f, kClickLevel * click_volume_, 0.05f);
        }
    }
    // What of this block is recorded: from the punch in, to the punch out.
    const int record_from = int(std::clamp<int64_t>(punch_clock_ - clock_, 0, block_));
    const int record_to = int(std::clamp<int64_t>(punch_out_clock_ == INT64_MAX ? block_ : punch_out_clock_ - clock_, 0, block_));
    const bool punching = recording_ && clock_ + block_ > punch_clock_ && clock_ < punch_out_clock_;
    record_from_ = record_from;
    record_to_ = record_to;
    punching_ = punching;
    for (Source* s : sources_) {
        if (s && isMic(s->kind)) {  // a microphone: what it hears (recorded once it is worked out), or its clips
            std::fill(s->playback.begin(), s->playback.end(), 0.0f);
            std::fill(s->playback_r.begin(), s->playback_r.end(), 0.0f);
            s->hear_input = s->input_on || (s->armed && (punching || !playing));
            if (playing && !s->hear_input) playClips(*s, counting);
            continue;
        }
        if (!s || !isLiveInput(s->kind)) continue;
        std::fill(s->playback.begin(), s->playback.end(), 0.0f);
        // What is heard from it, as Pro Tools has it: its input while input monitoring (I) is on, or while it is armed
        // and either stopped or recording (Auto Input: punched in, not in the pre-roll or post-roll); what it recorded
        // before, otherwise.
        const bool hear_input = s->input_on || (s->armed && (punching || !playing));
        s->instrument->setInputEnabled(hear_input);
        if (punching && s->armed && recorder_rt_ && record_to > record_from) {  // its input as it comes in, before the pedals, amp and inserts
            std::fill(take_.begin(), take_.end(), 0.0f);
            s->instrument->readInput(take_.data(), block_);
            recorder_rt_->write(recorder_rt_->slotOf(s->id), take_.data() + record_from, record_to - record_from);
        }
        if (playing && !hear_input) playClips(*s, counting);
    }
}

// A track's audio clips, from sample `from` of this block, into its playback: each from its file's chunks that the disk
// thread has read in (looked up afresh each block). Rendering offline, a chunk not in yet is read in there and then;
// playing, it is a gap, and counted.
void AudioEngine::playClips(Source& source, int from) {
    if (!source.track_rt || source.track_rt->clips.empty()) return;
    const bool realtime = realtime_.load(std::memory_order_acquire);
    float* out = source.playback.data();
    float* out_r = source.playback_r.empty() ? nullptr : source.playback_r.data();  // (a stereo track's second channel)
    for (const auto& clip : source.track_rt->clips) {
        StreamedFile& file = *clip.file;
        const double rate = file.rate();
        const int64_t frames = file.frames();
        const size_t kept = size_t(file.channels());  // a stereo file's two channels: both, for a stereo track; mixed, for one
        size_t held = SIZE_MAX;
        const float* data = nullptr;
        bool gap = false;
        auto frame = [&](int64_t k, float* l, float* r) {
            const size_t c = size_t(k) >> StreamedFile::kChunkShift;
            if (c != held) {
                held = c;
                data = file.chunk(c);
                if (!data && !realtime) {
                    file.load(c);
                    data = file.chunk(c);
                }
            }
            if (!data) return false;
            const size_t at = (size_t(k) & (StreamedFile::kChunkFrames - 1)) * kept;
            *l = data[at];
            *r = kept == 2 ? data[at + 1] : data[at];
            return true;
        };
        for (int i = from; i < block_; ++i) {
            const double t = block_seconds_[size_t(i)] - clip.start;
            if (t < 0.0 || t >= clip.length) continue;
            const double at = (t + clip.offset) * rate;
            const int64_t k = int64_t(at);
            if (k < 0 || k + 1 >= frames) continue;
            float al, ar, bl, br;
            if (!frame(k, &al, &ar) || !frame(k + 1, &bl, &br)) {
                gap = true;
                continue;
            }
            const float frac = float(at - double(k));
            float gain = clip.gain;  // and the fades, equal power: a quarter of a sine up, or down
            if (t < clip.fade_in) gain = float(std::sin(0.5 * kPi * t / clip.fade_in));
            if (clip.length - t < clip.fade_out) gain *= float(std::sin(0.5 * kPi * (clip.length - t) / clip.fade_out));
            const float l = al + (bl - al) * frac, r = ar + (br - ar) * frac;
            if (out_r) {
                out[i] += l * gain;
                out_r[i] += r * gain;
            } else {
                out[i] += (kept == 2 ? 0.5f * (l + r) : l) * gain;
            }
        }
        if (gap) streamer_.missed();
    }
}

// ── Automation (audio thread) ──────────────────────────────────────────────────────────────────────────────

namespace {

constexpr float kDryPan = 0.70710678f;  // a sound sent straight, as an equal-power pan has it at the centre

// Volume's value where the music is: glided between its points, level before the first and after the last.
float rampAt(const std::vector<AutoPoint>& points, double step) {
    if (step <= points.front().step) return points.front().value;
    if (step >= points.back().step) return points.back().value;
    auto after = std::upper_bound(points.begin(), points.end(), step, [](double v, const AutoPoint& p) { return v < p.step; });
    const AutoPoint& b = *after;
    const AutoPoint& a = *(after - 1);
    return b.step - a.step <= 1e-9 ? b.value : a.value + (b.value - a.value) * float((step - a.step) / (b.step - a.step));
}

// Mute's or the pedal's: the last point's at or before it, off before the first.
float switchAt(const std::vector<AutoPoint>& points, double step) {
    auto after = std::upper_bound(points.begin(), points.end(), step, [](double v, const AutoPoint& p) { return v < p.step; });
    return after == points.begin() ? 0.0f : (after - 1)->value;
}

float gainOf(float db) { return db <= -79.0f ? 0.0f : std::pow(10.0f, db / 20.0f); }

}  // namespace

// A source's fader and its mute, a sample at a time: as set, or while the music plays and its automation is read, as
// that has them. Every 32 samples it looks where the music is and glides there from where it was, so that a jump (a
// point, the loop going round) doesn't click; mute glides as a mute button does.
struct AudioEngine::Automating {
    static constexpr int kEvery = 32;
    Automating(AudioEngine& engine, Source& source) : e(engine), s(source) {
        const bool playing = e.sequencer_.running();
        lanes = playing && s.track_rt ? &s.track_rt->automation : nullptr;
        volume = lanes && s.read_volume && !lanes->volume.empty();
        mute = lanes && s.read_mute && !lanes->mute.empty();
    }
    void next(int i, float coef) {
        if (i % kEvery == 0 && (volume || mute)) {
            const int chunk = std::min(kEvery, e.block_ - i);
            const double at = e.sequencer_.position(e.clock_ + i + chunk);
            if (volume) ramp = (gainOf(rampAt(lanes->volume, at)) - s.gain) / float(chunk);
            if (mute) mute_to = switchAt(lanes->mute, at) > 0.5f ? 0.0f : 1.0f;
        }
        if (volume) s.gain += ramp;
        else s.gain += (s.gain_target - s.gain) * coef;
        s.auto_mute += (mute_to - s.auto_mute) * coef;
    }
    AudioEngine& e;
    Source& s;
    const TrackAutomation* lanes = nullptr;
    bool volume = false, mute = false;
    float ramp = 0.0f, mute_to = 1.0f;
};

void AudioEngine::chaseSustain(double step) {
    for (Source* s : sources_) {
        if (!s || !s->track_rt || !s->read_sustain || s->track_rt->automation.sustain.empty() || !playsNotes(s->kind)) continue;
        const bool down = switchAt(s->track_rt->automation.sustain, step - 1e-6) > 0.5f;
        if (down != s->auto_sustain) {
            s->auto_sustain = down;
            s->instrument->sustain(down);
        }
    }
}

// A source's controls as their automation has them where the music is (at the block's start): an amp's knobs, the
// plug-ins' controls (on its inserts, its Plug-in pedals, a plug-in instrument's own), its sends' levels. Each set only
// when it changes.
void AudioEngine::applyParams(Source& s, double at) {
    for (ParamLane& lane : s.track_rt->automation.params) {
        if (lane.points.empty()) continue;
        const float value = rampAt(lane.points, at);
        if (std::fabs(value - lane.last) < 1e-6f) continue;
        lane.last = value;
        PluginInstance* plugin = nullptr;
        switch (lane.target) {
            case ParamLane::AmpKnob:
                if (isAmp(s.kind) && lane.index >= 0 && lane.index < kAmpControls)
                    static_cast<Amp*>(s.instrument.get())->setControl(AmpControl(lane.index), value);
                break;
            case ParamLane::Insert:
                for (int i = 0; i < s.insert_board.count; ++i)
                    if (s.insert_board.slots[size_t(i)] == lane.index && s.insert_board.pedals[size_t(i)]->kind() == PedalKind::Plugin)
                        plugin = static_cast<PluginPedal*>(s.insert_board.pedals[size_t(i)])->plugin();
                break;
            case ParamLane::Pedal:
                if (lane.index >= 0 && lane.index < s.board.count && s.board.pedals[size_t(lane.index)]->kind() == PedalKind::Plugin)
                    plugin = static_cast<PluginPedal*>(s.board.pedals[size_t(lane.index)])->plugin();
                break;
            case ParamLane::Instrument:
                if (s.kind == InstrumentKind::PluginSynth) plugin = static_cast<PluginSynth*>(s.instrument.get())->plugin();
                break;
            case ParamLane::Send:
                if (lane.index >= 0 && lane.index < kMaxSends) s.sends[size_t(lane.index)].gain_target = gainOf(value);
                break;
            case ParamLane::Pan:
                s.pan_target = std::clamp(value, -1.0f, 1.0f);
                break;
            case ParamLane::PedalKnob:
                if (lane.index >= 0 && lane.index < s.board.count && lane.param < uint32_t(kPedalControls) &&
                    s.board.pedals[size_t(lane.index)]->kind() != PedalKind::Plugin)
                    s.board.pedals[size_t(lane.index)]->setControl(int(lane.param), std::clamp(value, 0.0f, 10.0f));
                break;
        }
        if (plugin) plugin->setParameter(lane.param, value);
    }
}

// One reflection of a source, read from its split history: `late` samples behind the clock (2 at least, for the cubic
// to have the samples after where it reads already played), gliding from `late_from` to `late_to` over the block,
// between samples through Lagrange's cubic; each band at a gain gliding from `from[b]` to `to[b]`, added into `out`;
// and if `spread_out`, its scattered part likewise into that.
void AudioEngine::readReflection(const Source& s, float late_from, float late_to, const float* from, const float* to, float* out,
                                 const float* spread_from, const float* spread_to, float* spread_out) const {
    const float* x = s.history.data();
    const float* lo = s.history_low.data();
    const float* bh = s.history_below_high.data();
    constexpr size_t mask = Source::kHistory - 1;
    const float n = float(block_);
    // Still (as most are, most of the time), and not running off the end of the history: each band read straight
    // through at one fraction between samples. Its level steady too, the bands and the cubic fold into twelve gains on
    // the three histories, sample by sample, which any compiler can do several samples at a time.
    if (late_to == late_from) {
        const double start = double(clock_) - double(late_from);
        const int64_t k = int64_t(std::floor(start));
        float c[4];
        lagrange4(float(start - double(k)), c);
        const size_t first = size_t(k - 1) & mask;
        if (first + size_t(block_) + 3 <= Source::kHistory) {
            const float* __restrict x0 = x + first;
            const float* __restrict lo0 = lo + first;
            const float* __restrict bh0 = bh + first;
            const auto steady = [](const float* a, const float* b) {
                for (int band = 0; band < 3; ++band)
                    if (std::fabs(b[band] - a[band]) > 1e-6f * std::fabs(a[band])) return false;
                return true;
            };
            // (low * g0 + (below - low) * g1 + (whole - below) * g2 is low * (g0 - g1) + below * (g1 - g2) + whole * g2)
            const auto add = [&](const float* g_from, const float* g_to, float* __restrict o) {
                if (steady(g_from, g_to)) {
                    const float l = g_from[0] - g_from[1], b = g_from[1] - g_from[2], w = g_from[2];
                    const float l0 = l * c[0], l1 = l * c[1], l2 = l * c[2], l3 = l * c[3];
                    const float b0 = b * c[0], b1 = b * c[1], b2 = b * c[2], b3 = b * c[3];
                    const float w0 = w * c[0], w1 = w * c[1], w2 = w * c[2], w3 = w * c[3];
                    for (int i = 0; i < block_; ++i)
                        o[i] += l0 * lo0[i] + l1 * lo0[i + 1] + l2 * lo0[i + 2] + l3 * lo0[i + 3] + b0 * bh0[i] + b1 * bh0[i + 1] +
                                b2 * bh0[i + 2] + b3 * bh0[i + 3] + w0 * x0[i] + w1 * x0[i + 1] + w2 * x0[i + 2] + w3 * x0[i + 3];
                    return;
                }
                const float g0 = g_from[0], g1 = g_from[1], g2 = g_from[2];
                const float d0 = (g_to[0] - g0) / n, d1 = (g_to[1] - g1) / n, d2 = (g_to[2] - g2) / n;
                for (int i = 0; i < block_; ++i) {
                    const float whole = c[0] * x0[i] + c[1] * x0[i + 1] + c[2] * x0[i + 2] + c[3] * x0[i + 3];
                    const float low = c[0] * lo0[i] + c[1] * lo0[i + 1] + c[2] * lo0[i + 2] + c[3] * lo0[i + 3];
                    const float below = c[0] * bh0[i] + c[1] * bh0[i + 1] + c[2] * bh0[i + 2] + c[3] * bh0[i + 3];
                    const float a = float(i + 1);
                    o[i] += low * (g0 + d0 * a) + (below - low) * (g1 + d1 * a) + (whole - below) * (g2 + d2 * a);
                }
            };
            add(from, to, out);
            if (spread_out) add(spread_from, spread_to, spread_out);
            return;
        }
    }
    const double glide = double(late_to - late_from) / double(block_);
    double at = double(clock_) - double(late_from) - glide;  // (where sample i is read: at + i * (1 - glide))
    const double each = 1.0 - glide;
    float g[3], dg[3], sg[3] = {}, dsg[3] = {};
    for (int b = 0; b < 3; ++b) {
        dg[b] = (to[b] - from[b]) / n;
        g[b] = from[b];
        if (spread_out) {
            dsg[b] = (spread_to[b] - spread_from[b]) / n;
            sg[b] = spread_from[b];
        }
    }
    for (int i = 0; i < block_; ++i, at += each) {
        const int64_t k = int64_t(std::floor(at));
        float c[4];
        lagrange4(float(at - double(k)), c);
        const size_t i0 = size_t(k - 1) & mask, i1 = size_t(k) & mask, i2 = size_t(k + 1) & mask, i3 = size_t(k + 2) & mask;
        const float whole = c[0] * x[i0] + c[1] * x[i1] + c[2] * x[i2] + c[3] * x[i3];
        const float low = c[0] * lo[i0] + c[1] * lo[i1] + c[2] * lo[i2] + c[3] * lo[i3];
        const float below = c[0] * bh[i0] + c[1] * bh[i1] + c[2] * bh[i2] + c[3] * bh[i3];
        const float mid = below - low, high = whole - below;
        for (int b = 0; b < 3; ++b) g[b] += dg[b];
        out[i] += low * g[0] + mid * g[1] + high * g[2];
        if (spread_out) {
            for (int b = 0; b < 3; ++b) sg[b] += dsg[b];
            spread_out[i] += low * sg[0] + mid * sg[1] + high * sg[2];
        }
    }
}

// A source's sound as it reaches a microphone: read from its history `late` samples behind the clock (gliding from
// `late_from` to `late_to` across the block), and kMicLead more, between samples through the sinc, into `out`.
void AudioEngine::readHistory(const float* history, double late_from, double late_to, float* out) const {
    constexpr size_t mask = Source::kHistory - 1;
    float w[Sinc16::kTaps];
    if (late_from == late_to) {  // still: one set of weights for the block, tap by tap down it where it doesn't wrap round
        const double start = double(clock_) - late_from - double(kMicLead);
        const int64_t k = int64_t(std::floor(start));
        Sinc16::weights(float(start - double(k)), w);
        const size_t first = size_t(k - Sinc16::kBefore) & mask;
        std::fill(out, out + block_, 0.0f);
        if (first + size_t(block_ + Sinc16::kTaps) <= Source::kHistory) {
            const float* __restrict x = history + first;
            float* __restrict o = out;
            for (int t = 0; t < Sinc16::kTaps; ++t) {
                const float wt = w[t];
                for (int i = 0; i < block_; ++i) o[i] += wt * x[i + t];
            }
            return;
        }
        for (int i = 0; i < block_; ++i)
            for (int t = 0; t < Sinc16::kTaps; ++t) out[i] += w[t] * history[(first + size_t(i + t)) & mask];
        return;
    }
    for (int i = 0; i < block_; ++i) {  // gliding: each sample its own weights
        const double late = late_from + (late_to - late_from) * double(i + 1) / double(block_);
        const double at = double(clock_ + i) - late - double(kMicLead);
        const int64_t k = int64_t(std::floor(at));
        Sinc16::weights(float(at - double(k)), w);
        const size_t first = size_t(k - Sinc16::kBefore) & mask;
        float y = 0.0f;
        for (int t = 0; t < Sinc16::kTaps; ++t) y += w[t] * history[(first + size_t(t)) & mask];
        out[i] = y;
    }
}

// What a loudspeaker's beaming leaves of each band, at the band's middle (the low-pass at `cut_hz` it is otherwise heard
// through, MicFilter::LowPass at a Q of 0.6): a reflection carries it as three gains rather than a filter.
static std::array<float, 3> beamingBands(float cut_hz) {
    static constexpr float kMiddle[3] = {300.0f, 2500.0f, 12000.0f};
    std::array<float, 3> out{};
    for (size_t b = 0; b < 3; ++b) {
        const float r = kMiddle[b] / std::max(cut_hz, 20.0f), q = 0.6f;
        out[b] = 1.0f / std::sqrt((1.0f - r * r) * (1.0f - r * r) + (r / q) * (r / q));
    }
    return out;
}

// A reflection's loss to the air over `metres`, band by band, kept with the distance it was worked out for (reflections
// mostly stay put, and there are many of them).
static void airOver(float metres, float& at, float* air) {
    if (metres == at) return;
    at = metres;
    for (int b = 0; b < 3; ++b) air[b] = std::exp(-SourceSpatializer::kAirAbsorption[b] * metres);
}

// A loudspeaker's beaming glided toward its target (in octaves), and settled once within a thousandth of it.
static void glideCut(float& cut, float target, float glide) {
    if (cut == target) return;
    cut = std::exp(std::log(cut) + (std::log(target) - std::log(cut)) * glide);
    if (std::fabs(cut - target) < 1e-3f * target) cut = target;
}

// The listener's reflections: each source's off each of the room's surfaces, off two of them, and off each wall standing
// in it, read from its split history as much later than its direct sound as the way round by the surface is longer
// (sooner by as much as the field's binaural rendering is later than a source's own, while binaural is on), dulled by
// the air and by the beaming of a loudspeaker, as much of each band as the surface sends back as a mirror, quieter by
// the distance law, and put in the field at the way it comes from. What the surfaces scatter goes in too, spread out in time and from all over each surface.
void AudioEngine::playReflections(float binaural_from) {
    reflections_.clear();
    for (auto& bus : echo_scatter_) std::fill(bus.begin(), bus.end(), 0.0f);
    const float rate = float(sr_);
    const float sooner_to = binaural_mix_ * float(reflections_.binauralLate());
    const float furthest = float(Source::kHistory - size_t(block_) - 4);
    const float glide = 1.0f - std::exp(-float(block_) / (0.05f * rate));
    for (Source* s : sources_) {
        if (!s || !inRoom(s->kind) || s->history.empty()) continue;
        for (int f = 0; f < kEchoes; ++f) {
            Source::Echo& e = s->echoes[size_t(f)];
            if (e.gain_target <= 0.0f && e.gain <= 1e-4f) {  // none (or faded out): heard afresh when it comes back
                e.gain = 0.0f;
                e.late = -1.0f;
                continue;
            }
            const float reflected = length(sub(e.image, listener_pos_)), straight = length(sub(e.source, listener_pos_));
            const float late_to = std::clamp((reflected - straight) / kSpeedOfSound * rate - sooner_to, 2.0f, furthest);
            const bool fresh = e.late < 0.0f;
            const float late_from = fresh ? late_to : e.late;
            e.late = late_to;
            const Vec3 way_to = steam_.relativeDirection(e.image, listener_pos_, listener_ahead_, listener_up_);
            const Vec3 way_from = fresh ? way_to : e.way;
            e.way = way_to;
            // Each band's level (what the surface sends back, the air, a loudspeaker's beaming), at the start of the block
            // and at its end.
            const float loud = distanceLaw(SourceSpatializer::kRefDistance / std::max(SourceSpatializer::kRefDistance, reflected));
            airOver(reflected, e.air_at, e.air);
            float as_mirror[2][3], spread[2][3];
            for (int end = 0; end < 2; ++end) {
                if (end == 1) {
                    for (size_t b = 0; b < 3; ++b) {
                        e.mirror[b] += (e.mirror_target[b] - e.mirror[b]) * glide;
                        e.scatter[b] += (e.scatter_target[b] - e.scatter[b]) * glide;
                    }
                    e.gain += (e.gain_target - e.gain) * glide;
                    glideCut(e.cut, e.cut_target, glide);
                }
                const std::array<float, 3> beam = e.filtered ? beamingBands(e.cut) : std::array<float, 3>{1.0f, 1.0f, 1.0f};
                for (int b = 0; b < 3; ++b) {
                    const float level = e.gain * loud * e.air[b] * beam[size_t(b)];
                    as_mirror[end][b] = e.mirror[size_t(b)] * level;
                    spread[end][b] = e.scatter[size_t(b)] * level;
                }
            }
            const bool spreads = spread[0][0] + spread[0][1] + spread[0][2] + spread[1][0] + spread[1][1] + spread[1][2] > 0.0f;
            std::fill(echo_.begin(), echo_.end(), 0.0f);
            readReflection(*s, late_from, late_to, as_mirror[0], as_mirror[1], echo_.data(), spread[0], spread[1],
                           spreads ? echo_scatter_[size_t(e.bus)].data() : nullptr);
            reflections_.add(echo_.data(), way_from, way_to, 1.0f, e.second ? 1 : 2);
        }
    }
    // What each surface scattered: spread out in time, and from all over it (from its nearest point, widely). Once
    // nothing is scattered, its smear runs on a little, for its tail, and then rests.
    const std::array<Face, kFaces> room = faces();
    for (int f = 0; f < kScatterBuses; ++f) {
        float* bus = echo_scatter_[size_t(f)].data();
        int& resting = echo_quiet_[size_t(f)];
        bool silent = true;
        for (int i = 0; i < block_ && silent; ++i) silent = bus[i] == 0.0f;
        resting = silent ? resting + 1 : 0;
        if (resting > 2 + 2048 / std::max(block_, 1)) continue;
        echo_smear_[size_t(f)].process(bus, block_);
        Vec3 nearest = listener_pos_;
        if (f < kFaces) {  // the room's own: the nearest point of it
            float& on = room[size_t(f)].axis == 0 ? nearest.x : (room[size_t(f)].axis == 1 ? nearest.y : nearest.z);
            on = room[size_t(f)].plane;
        } else if (scatter_wall_on_[size_t(f - kFaces)]) {  // a wall standing in it: the nearest point of that
            const std::array<float, 5>& w = scatter_walls_[size_t(f - kFaces)];
            const float dx = w[2] - w[0], dz = w[3] - w[1], run = dx * dx + dz * dz;
            const float t = run > 1e-6f ? std::clamp(((listener_pos_.x - w[0]) * dx + (listener_pos_.z - w[1]) * dz) / run, 0.0f, 1.0f) : 0.0f;
            nearest = {w[0] + dx * t, std::clamp(listener_pos_.y, 0.0f, w[4]), w[1] + dz * t};
        }
        const Vec3 way = steam_.relativeDirection(nearest, listener_pos_, listener_ahead_, listener_up_);
        reflections_.add(bus, way, way, 0.4f);
    }
    reflections_.render(room_l_.data(), room_r_.data(), binaural_from, binaural_mix_);
}

// What a microphone hears this block, into its mono: each source in the room from its history, as late as its sound
// takes to arrive (glided as either moves, so a move bends the pitch as it would), as loud as the distance leaves it,
// its bands as the air and the walls leave them (split at 800 Hz and 8 kHz, as Steam Audio splits the listener's);
// the room's reverb, as diffuse there as anywhere; and its gain, before anything records it.
void AudioEngine::hearCapsule(Source& mic, int capsule_index, float* out, float reverb_level, float glide) {
    std::fill(out, out + block_, 0.0f);
    Source::Capsule& capsule = mic.capsules[size_t(capsule_index)];
    auto& sound = capsule.sound;
    const double rate = double(sr_);
    const float lows = 1.0f - std::exp(-2.0f * float(kPi) * SourceSpatializer::kBandEdges[0] / float(sr_));
    const float highs = 1.0f - std::exp(-2.0f * float(kPi) * SourceSpatializer::kBandEdges[1] / float(sr_));
    const double furthest = double(Source::kHistory - size_t(block_) - 4 - kMicLead - Sinc16::kBefore);  // samples late it can hear at most
    auto loudness = [&](float d) { return std::pow(SourceSpatializer::kRefDistance / std::max(d, kMicNearest), falloff_); };
    const Vec3 aim_from = capsule.aim;  // which way it points, glided as it turns
    capsule.aim = turnToward(capsule.aim, capsule.aim_target, glide);
    const float* pressure = sound.polar.pressure.data();
    const float* gradient = sound.polar.gradient.data();
    const float k2 = 2.0f * float(sr_);  // (the bilinear transform's)
    const float most = std::pow(10.0f, kProximityMaxDb / 20.0f);
    // One way a sound reaches it: read from the source's history as late as the way is long (gliding from `from_m`
    // metres to `to_m`), through `filters` (a loudspeaker's cone's, or none), split into the three bands (each dulled by
    // the air and the walls: `air_from` to `air_to`), heard by the pattern from the way it arrives (the cosine off its
    // axis gliding from `off_from` to `off_to`), the gradient part with its proximity effect for a wave `wave` metres
    // round, at a level gliding from `gain_from` to `gain_to`; `state` is the band split's and the proximity filter's
    // (low, below_high, near_in, near_out). What a surface scatters of it (`spread_from` to `spread_to` of each band,
    // as the capsule hears a diffuse sound) goes into `spread_out`, to be spread out in time.
    const auto hear = [&](const float* heard, float from_m, float to_m, const float* air_from, const float* air_to, float off_from,
                          float off_to, float wave, float gain_from, float gain_to, float* state, EqFilter* filters, int filter_count,
                          const float* spread_from = nullptr, const float* spread_to = nullptr, float* spread_out = nullptr) {
        const float near_corner = kSpeedOfSound / std::max(wave, kProximityNearest);  // radians a second
        const float wide = near_corner / most, n0 = k2 + wide;
        const float pb0 = (k2 + near_corner) / n0, pb1 = (near_corner - k2) / n0, pa1 = (wide - k2) / n0;
        float& low_s = state[0];
        float& below_high_s = state[1];
        float& near_in = state[2];
        float& near_out = state[3];
        // As late as it is heard (samples), gliding straight from one end of the block to the other, read between samples.
        readHistory(heard, std::clamp(double(from_m) / kSpeedOfSound * rate, 0.0, furthest),
                    std::clamp(double(to_m) / kSpeedOfSound * rate, 0.0, furthest), read_.data());
        for (int i = 0; i < block_; ++i) {
            const float a = float(i + 1) / float(block_);
            float x = read_[size_t(i)];
            for (int f = 0; f < filter_count; ++f) x = filters[f].process(x);
            low_s += (x - low_s) * lows;
            below_high_s += (x - below_high_s) * highs;
            const float low = low_s * (air_from[0] + (air_to[0] - air_from[0]) * a);
            const float mid = (below_high_s - low_s) * (air_from[1] + (air_to[1] - air_from[1]) * a);
            const float high = (x - below_high_s) * (air_from[2] + (air_to[2] - air_from[2]) * a);
            float y = pressure[0] * low + pressure[1] * mid + pressure[2] * high;
            if (sound.gradient) {
                const float g = gradient[0] * low + gradient[1] * mid + gradient[2] * high;
                const float near = pb0 * g + pb1 * near_in - pa1 * near_out;
                near_in = g;
                near_out = near;
                y += (off_from + (off_to - off_from) * a) * near;
            }
            const float level = gain_from + (gain_to - gain_from) * a;
            out[i] += y * level;
            if (spread_out)
                spread_out[i] += (low_s * (spread_from[0] + (spread_to[0] - spread_from[0]) * a) +
                                  (below_high_s - low_s) * (spread_from[1] + (spread_to[1] - spread_from[1]) * a) +
                                  (x - below_high_s) * (spread_from[2] + (spread_to[2] - spread_from[2]) * a)) * level;
        }
    };
    // A reflection: read already split (readReflection), each band at a level that has in it the pattern from the way it
    // arrives, the air, what the surface sends back, and a loudspeaker's beaming, at the start of the block and at its
    // end; what the surface scatters into its bus, as the capsule hears a diffuse sound. Without the proximity effect: a
    // reflection comes from too far away for much of one.
    const auto reflect = [&](const Source& s, Source::Pickup::Way& way) {
        const float furthest_late = float(furthest);
        float heard[2][3], spread[2][3], late[2];
        for (int end = 0; end < 2; ++end) {
            if (end == 1) {
                way.distance += (way.distance_target - way.distance) * glide;
                way.nearness += (way.nearness_target - way.nearness) * glide;
                way.gain += (way.gain_target - way.gain) * glide;
                way.from = turnToward(way.from, way.from_target, glide);
                glideCut(way.cut, way.cut_target, glide);
                for (int b = 0; b < 3; ++b) {
                    way.bands[b] += (way.bands_target[b] - way.bands[b]) * glide;
                    way.scatter[b] += (way.scatter_target[b] - way.scatter[b]) * glide;
                }
            }
            late[end] = std::clamp(way.distance / kSpeedOfSound * float(rate), 0.0f, furthest_late) + float(kMicLead);
            const float level = way.gain * distanceLaw(way.nearness);
            const float off = dot(way.from, end == 0 ? aim_from : capsule.aim);
            const std::array<float, 3> beam = way.filtered ? beamingBands(way.cut) : std::array<float, 3>{1.0f, 1.0f, 1.0f};
            airOver(way.distance, way.air_at, way.air);
            for (size_t b = 0; b < 3; ++b) {
                const float carried = level * way.air[b] * beam[b];
                heard[end][b] = carried * way.bands[b] * (pressure[b] + (sound.gradient ? gradient[b] * off : 0.0f));
                spread[end][b] = carried * way.scatter[b] * sound.diffuse[b];
            }
        }
        const bool spreads = way.surface >= 0 && spread[0][0] + spread[0][1] + spread[0][2] + spread[1][0] + spread[1][1] + spread[1][2] > 0.0f;
        readReflection(s, late[0], late[1], heard[0], heard[1], out, spread[0], spread[1],
                       spreads ? capsule.scatter[size_t(way.surface)].data() : nullptr);
    };
    for (auto& bus : capsule.scatter) std::fill(bus.begin(), bus.end(), 0.0f);
    for (size_t j = 0; j < sources_.size(); ++j) {
        const Source* s = sources_[j];
        if (!s || !inRoom(s->kind) || s->history.empty()) continue;
        Source::Pickup& k = (*capsule.pickups)[j];
        if (k.target < 0.0f) continue;
        if (k.distance < 0.0f) {  // heard for the first time: from where it is
            k.distance = k.target;
            std::copy(k.band_target, k.band_target + 3, k.band);
            k.from = k.from_target;
        }
        const float from = k.distance;
        float band_from[3];
        k.distance += (k.target - k.distance) * glide;
        for (int b = 0; b < 3; ++b) {
            band_from[b] = k.band[b];
            k.band[b] += (k.band_target[b] - k.band[b]) * glide;
        }
        // The air dulls each band the further it goes; the walls (band) as the way round them has it.
        const auto air = [&](float metres, const float* band, float* gains) {
            for (int b = 0; b < 3; ++b) gains[b] = std::exp(-SourceSpatializer::kAirAbsorption[b] * metres) * band[b];
        };
        const Vec3 way_from = k.from;
        k.from = turnToward(k.from, k.from_target, glide);
        if (k.ways == 0) {  // a point, from where it stands
            float air_from[3], air_to[3];
            air(from, band_from, air_from);
            air(k.distance, k.band, air_to);
            float state[4] = {k.low, k.below_high, k.near_in, k.near_out};
            hear(s->history.data(), from, k.distance, air_from, air_to, dot(way_from, aim_from), dot(k.from, capsule.aim), k.distance,
                 loudness(from), loudness(k.distance), state, nullptr, 0);
            k.low = state[0];
            k.below_high = state[1];
            k.near_in = state[2];
            k.near_out = state[3];
            continue;
        }
        // Each way it comes (a loudspeaker's cones, radiation.h, or a point; and each off the floor): its level
        // (levelling off close up, for a cone, as its near field has it) raised to the room's distance law.
        for (int w = 0; w < k.ways; ++w) {
            Source::Pickup::Way& way = k.way[size_t(w)];
            if (way.distance < 0.0f) continue;  // (not told yet)
            if (way.gain_target == 0.0f && std::fabs(way.gain) < 1e-5f) {  // (a reflection there isn't, just now)
                way.gain = 0.0f;
                continue;
            }
            if (way.reflection) {
                reflect(*s, way);
                continue;
            }
            const float d_from = way.distance, g_from = way.gain * std::pow(way.nearness, falloff_);
            const Vec3 arrive_from = way.from;
            way.distance += (way.distance_target - way.distance) * glide;
            way.nearness += (way.nearness_target - way.nearness) * glide;
            way.gain += (way.gain_target - way.gain) * glide;
            way.from = turnToward(way.from, way.from_target, glide);
            if (way.filtered) {
                way.cut = std::exp(std::log(way.cut) + (std::log(way.cut_target) - std::log(way.cut)) * glide);
                way.low_db += (way.low_target - way.low_db) * glide;
                way.high_db += (way.high_target - way.high_db) * glide;
                way.filters[0].design({MicFilter::LowPass, std::min(way.cut, 0.45f * float(sr_)), 0.0f, 0.6f}, float(sr_));
                way.filters[1].design({MicFilter::LowShelf, kNearLowHz, way.low_db, 0.707f}, float(sr_));
                way.filters[2].design({MicFilter::HighShelf, kCapHighHz, way.high_db, 0.707f}, float(sr_));
            }
            float air_from[3], air_to[3];
            air(d_from, band_from, air_from);
            air(way.distance, k.band, air_to);
            // Off a surface: what it sends back of each band as a mirror would, and what it scatters (heard as a diffuse
            // sound is: as the pattern hears one from all round).
            float spread_from[3], spread_to[3];
            const bool spreads = way.surface >= 0 && (way.scatter[0] + way.scatter[1] + way.scatter[2] + way.scatter_target[0] +
                                                      way.scatter_target[1] + way.scatter_target[2]) > 0.0f;
            for (int b = 0; b < 3; ++b) {
                spread_from[b] = air_from[b] * way.scatter[b] * sound.diffuse[size_t(b)];
                air_from[b] *= way.bands[b];
                way.bands[b] += (way.bands_target[b] - way.bands[b]) * glide;
                way.scatter[b] += (way.scatter_target[b] - way.scatter[b]) * glide;
                spread_to[b] = air_to[b] * way.scatter[b] * sound.diffuse[size_t(b)];
                air_to[b] *= way.bands[b];
            }
            float state[4] = {way.low, way.below_high, way.near_in, way.near_out};
            const float wave = std::sqrt(way.distance * way.distance + s->cone_radius * s->cone_radius);
            hear(s->history.data(), d_from, way.distance, air_from, air_to, dot(arrive_from, aim_from), dot(way.from, capsule.aim), wave,
                 g_from, way.gain * std::pow(way.nearness, falloff_), state, way.filters.data(), way.filtered ? 3 : 0,
                 spreads ? spread_from : nullptr, spreads ? spread_to : nullptr, spreads ? capsule.scatter[size_t(way.surface)].data() : nullptr);
            way.low = state[0];
            way.below_high = state[1];
            way.near_in = state[2];
            way.near_out = state[3];
        }
    }
    // What the surfaces scattered to it, spread out in time (each one's smear run on a little after, for its tail).
    for (int f = 0; f < kScatterBuses; ++f) {
        float* bus = capsule.scatter[size_t(f)].data();
        bool silent = true;
        for (int i = 0; i < block_ && silent; ++i) silent = bus[i] == 0.0f;
        int& resting = capsule.quiet[size_t(f)];
        resting = silent ? resting + 1 : 0;
        if (resting > 2 + 2048 / std::max(block_, 1)) continue;
        capsule.smear[size_t(f)].process(bus, block_);
        for (int i = 0; i < block_; ++i) out[i] += bus[i];
    }
    // The room's reverb, as diffuse there as anywhere (whatever its fader says): what of it the pattern hears, band by
    // band; and its noise. Then its response, its sensitivity, and its gain, before anything records it. (A stereo
    // mic's two hear the reverb's two sides, as two ears would; the gain glides once, with the first.)
    const float* rev_a = capsule_index == 0 ? rev_l_.data() : rev_r_.data();
    const float* rev_b = capsule_index == 0 ? rev_r_.data() : rev_l_.data();
    const float coef = 1.0f - std::exp(-1.0f / (0.01f * float(sr_)));
    const float gain_from = mic.volume;
    if (capsule_index == 0) mic.volume += (mic.volume_target - mic.volume) * (1.0f - std::pow(1.0f - coef, float(block_)));
    for (int i = 0; i < block_; ++i) {
        const float r = (mic.capsule_count == 1 ? (rev_a[size_t(i)] + rev_b[size_t(i)]) * kDryPan
                                                 : (rev_a[size_t(i)] * 0.9f + rev_b[size_t(i)] * 0.1f) * 1.104f) * reverb_level;
        sound.rev_low += (r - sound.rev_low) * lows;
        sound.rev_below_high += (r - sound.rev_below_high) * highs;
        out[i] += sound.rev_low * sound.diffuse[0] + (sound.rev_below_high - sound.rev_low) * sound.diffuse[1] +
                  (r - sound.rev_below_high) * sound.diffuse[2];
        float y = out[i] + capsule.hiss.next() * sound.noise;
        for (int f = 0; f < sound.eq_count; ++f) y = sound.eq[size_t(f)].process(y);
        out[i] = y * sound.sensitivity * (gain_from + (mic.volume - gain_from) * float(i + 1) / float(block_));
    }
}

// One source's block: an instrument's sound (or a microphone's: what it hears, or its clips), through its inserts,
// volume, fader and mute, metered, into the room for the listener (a microphone's, in the middle of the stereo) and
// into its folder or the master, and its sends.
void AudioEngine::playSource(size_t index, float binaural_from, float glide, float wall_glide, float mute_coef) {
    Source* s = sources_[index];
    const bool mic = isMic(s->kind);  // (a microphone's mono holds what it plays: what it hears, or its clips)
    float* mono = s->mono.data();
    if (!mic) {
        std::fill(s->mono.begin(), s->mono.end(), 0.0f);
        if (s->kind == InstrumentKind::PluginSynth)  // the room's tempo, for plug-ins that keep time
            static_cast<PluginSynth*>(s->instrument.get())->setBeatSamples(double(bar_timing_[1]) / 4.0);
        s->instrument->render(mono, block_);
    }
    if (s->insert_board.count > 0) {  // its inserts, before its fader (and, an instrument's, before the room too)
        const PedalTiming timing{double(bar_timing_[1]) / 4.0, bar_timing_[0], bar_timing_[1]};
        for (int p = 0; p < s->insert_board.count; ++p) s->insert_board.pedals[size_t(p)]->process(mono, block_, timing);
    }

    double energy = 0.0, pre_energy = 0.0, room_energy = 0.0;
    float peak = 0.0f, pre_peak = 0.0f, room_peak = 0.0f;
    Automating automating(*this, *s);
    bool sending = false, sending_pre = false;  // its sends: to an aux track's bus, after its fader or before
    for (const auto& send : s->sends)
        if (send.bus >= 0 && (send.on || send.gain > 1e-6f)) {
            sending = true;
            sending_pre = sending_pre || send.pre;
        }
    float* heard = s->history.empty() ? nullptr : s->history.data();
    float* room = s->room.empty() ? nullptr : s->room.data();
    // A loudspeaker's sound all round, as the reverb hears it: duller than on its axis (its beaming).
    const float power = s->facing && s->power_cut > 0.0f ? 1.0f - std::exp(-2.0f * float(kPi) * s->power_cut / float(sr_)) : 0.0f;
    for (int i = 0; i < block_; ++i) {
        if (!mic) {  // (a microphone's gain came before it was recorded)
            s->volume += (s->volume_target - s->volume) * mute_coef;
            mono[i] *= s->volume;
        }
        if (sending_pre) s->pre[size_t(i)] = mono[i];
        pre_energy += double(mono[i]) * mono[i];  // what reaches the fader
        pre_peak = std::max(pre_peak, std::fabs(mono[i]));
        if (room) {  // its sound in the room: at its level there, unless it is muted there
            s->room_gain += (s->room_gain_target - s->room_gain) * mute_coef;
            s->room_mute += (s->room_mute_target - s->room_mute) * mute_coef;
            const float r = mono[i] * s->room_gain * s->room_mute;
            room[i] = r;
            if (heard) {  // (as the microphones hear it, and its reflections are heard)
                const size_t at = size_t(clock_ + i) & (Source::kHistory - 1);
                heard[at] = r;
                s->split_low += (r - s->split_low) * split_lows_;
                s->split_below_high += (r - s->split_below_high) * split_highs_;
                s->history_low[at] = s->split_low;
                s->history_below_high[at] = s->split_below_high;
            }
            if (power > 0.0f) {  // the room hears the source even when a wall blocks your view of it
                s->power_state += (r - s->power_state) * power;
                send_[size_t(i)] += s->power_state * s->send;
            } else {
                send_[size_t(i)] += r * s->send;
            }
            room_energy += double(r) * r;
            room_peak = std::max(room_peak, std::fabs(r));
        }
        // Its direct output, into the mix (a microphone's track): its fader (or its automation), mute and solo.
        s->mute_gain += (s->mute_target - s->mute_gain) * mute_coef;
        s->solo_gain += (s->solo_target - s->solo_gain) * mute_coef;
        automating.next(i, mute_coef);
        mono[i] *= s->gain * s->mute_gain * s->auto_mute * s->solo_gain;
        energy += double(mono[i]) * mono[i];
        peak = std::max(peak, std::fabs(mono[i]));
    }
    levels_[size_t(s->id)].store(float(std::sqrt(energy / block_)), std::memory_order_relaxed);
    if (peak > peaks_[size_t(s->id)].load(std::memory_order_relaxed)) peaks_[size_t(s->id)].store(peak, std::memory_order_relaxed);
    pre_levels_[size_t(s->id)].store(float(std::sqrt(pre_energy / block_)), std::memory_order_relaxed);
    if (pre_peak > pre_peaks_[size_t(s->id)].load(std::memory_order_relaxed))
        pre_peaks_[size_t(s->id)].store(pre_peak, std::memory_order_relaxed);
    room_levels_[size_t(s->id)].store(float(std::sqrt(room_energy / block_)), std::memory_order_relaxed);
    if (room_peak > room_peaks_[size_t(s->id)].load(std::memory_order_relaxed))
        room_peaks_[size_t(s->id)].store(room_peak, std::memory_order_relaxed);

    if (room && s->facing) {  // a loudspeaker, from where you stand against its baffle: its beaming, and its shadow behind
        const float gain_from = s->facing_gain;
        s->facing_cut = std::exp(std::log(s->facing_cut) + (std::log(s->facing_cut_target) - std::log(s->facing_cut)) * glide);
        s->facing_gain += (s->facing_gain_target - s->facing_gain) * glide;
        s->facing_lp.design({MicFilter::LowPass, std::min(s->facing_cut, 0.45f * float(sr_)), 0.0f, 0.6f}, float(sr_));
        for (int i = 0; i < block_; ++i)
            room[i] = s->facing_lp.process(room[i]) * (gain_from + (s->facing_gain - gain_from) * float(i + 1) / float(block_));
    }
    if (room) {  // placed in the room, for the listener: the room's own mix
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
        s->spatializer.process(room, room_l_.data(), room_r_.data(), p);
    }

    // Its direct output where its pan puts it in the stereo (equal power), as a mono track's: into its folder, or the mix.
    Source* bus = s->output >= 0 && size_t(s->output) < sources_.size() ? sources_[size_t(s->output)] : nullptr;
    float* to_l = bus && isBus(bus->kind) ? bus->bus_l.data() : mix_l_.data();
    float* to_r = bus && isBus(bus->kind) ? bus->bus_r.data() : mix_r_.data();
    const float pan_from = s->pan;
    s->pan += (s->pan_target - s->pan) * wall_glide;
    for (int i = 0; i < block_; ++i) {
        const float pan = pan_from + (s->pan - pan_from) * float(i + 1) / float(block_);
        const float angle = (pan + 1.0f) * 0.25f * float(kPi);
        s->out_l[size_t(i)] = mono[i] * std::cos(angle);
        s->out_r[size_t(i)] = mono[i] * std::sin(angle);
    }
    playOut(*s, s->out_l.data(), s->out_r.data(), to_l, to_r);
    if (sending) {  // (before it is held back: each send is held back to meet the others at its aux)
        const float muted = s->mute_gain * s->auto_mute * s->solo_gain;
        for (int k = 0; k < kMaxSends; ++k) {
            const auto& send = s->sends[size_t(k)];
            Source* aux = send.bus >= 0 && size_t(send.bus) < sources_.size() ? sources_[size_t(send.bus)] : nullptr;
            if (!aux || !isBus(aux->kind)) continue;
            if (send.pre)  // its own sound before its fader, in the middle of the stereo
                playSend(*s, k, *aux, s->pre.data(), s->pre.data(), kDryPan * muted, mute_coef);
            else
                playSend(*s, k, *aux, s->out_l.data(), s->out_r.data(), 1.0f, mute_coef);
        }
    }

    if (s->fade_blocks >= 0 && --s->fade_blocks < 0) {  // removed and faded out: forget it and hand it back
        sources_[index] = nullptr;
        levels_[index].store(0.0f, std::memory_order_relaxed);
        peaks_[index].store(0.0f, std::memory_order_relaxed);
        pre_levels_[index].store(0.0f, std::memory_order_relaxed);
        pre_peaks_[index].store(0.0f, std::memory_order_relaxed);
        room_levels_[index].store(0.0f, std::memory_order_relaxed);
        room_peaks_[index].store(0.0f, std::memory_order_relaxed);
        s->released.store(true, std::memory_order_release);  // must be the last thing this thread does with it
    }
}

// A stereo mic's track (its mono and mono_r hold what it plays: what its two capsules hear, or its clips), as a bus's
// strip is: mid and side decoded to left and right, its inserts in stereo, its fader and mute, its balance, metered,
// into its folder or the master, and its sends.
void AudioEngine::playStereoMic(size_t index, float wall_glide, float mute_coef) {
    Source* s = sources_[index];
    float* l = s->mono.data();
    float* r = s->mono_r.data();
    if (s->mid_side) {  // L = M + S, R = M - S, the side as wide as it is set
        const float width_from = s->width;
        s->width += (s->width_target - s->width) * wall_glide;
        for (int i = 0; i < block_; ++i) {
            const float side = r[i] * (width_from + (s->width - width_from) * float(i + 1) / float(block_));
            const float mid = l[i];
            l[i] = mid + side;
            r[i] = mid - side;
        }
    }
    if (s->insert_board.count > 0) {
        const PedalTiming timing{double(bar_timing_[1]) / 4.0, bar_timing_[0], bar_timing_[1]};
        for (int p = 0; p < s->insert_board.count; ++p) s->insert_board.pedals[size_t(p)]->processStereo(l, r, block_, timing);
    }
    auto bus_at = [&](int id) -> Source* {
        Source* b = id >= 0 && id < kSourceSlots ? sources_[size_t(id)] : nullptr;
        return b && isBus(b->kind) ? b : nullptr;
    };
    bool sending = false, sending_pre = false;
    for (const auto& send : s->sends)
        if (bus_at(send.bus) && (send.on || send.gain > 1e-6f)) {
            sending = true;
            sending_pre = sending_pre || send.pre;
        }
    Source* into = bus_at(s->output);
    float* to_l = into ? into->bus_l.data() : mix_l_.data();
    float* to_r = into ? into->bus_r.data() : mix_r_.data();
    double energy = 0.0, pre_energy = 0.0;
    float peak = 0.0f, pre_peak = 0.0f;
    Automating automating(*this, *s);
    const float pan_from = s->pan;
    s->pan += (s->pan_target - s->pan) * wall_glide;
    for (int i = 0; i < block_; ++i) {
        pre_energy += 0.5 * (double(l[i]) * l[i] + double(r[i]) * r[i]);
        pre_peak = std::max(pre_peak, std::max(std::fabs(l[i]), std::fabs(r[i])));
        if (sending_pre) {
            s->pre[size_t(i)] = l[i];
            s->pre_r[size_t(i)] = r[i];
        }
        s->mute_gain += (s->mute_target - s->mute_gain) * mute_coef;
        s->solo_gain += (s->solo_target - s->solo_gain) * mute_coef;
        automating.next(i, mute_coef);
        const float g = s->gain * s->mute_gain * s->auto_mute * s->solo_gain;
        const float a = l[i] * g, b = r[i] * g;
        energy += 0.5 * (double(a) * a + double(b) * b);
        peak = std::max(peak, std::max(std::fabs(a), std::fabs(b)));
        // Its balance: turned one way, the other side is turned down (equal power), as a stereo track's.
        const float pan = pan_from + (s->pan - pan_from) * float(i + 1) / float(block_);
        const float keep_l = pan > 0.0f ? std::cos(pan * 0.5f * float(kPi)) : 1.0f, keep_r = pan < 0.0f ? std::cos(-pan * 0.5f * float(kPi)) : 1.0f;
        s->out_l[size_t(i)] = a * keep_l;
        s->out_r[size_t(i)] = b * keep_r;
    }
    playOut(*s, s->out_l.data(), s->out_r.data(), to_l, to_r);
    levels_[size_t(s->id)].store(float(std::sqrt(energy / block_)), std::memory_order_relaxed);
    if (peak > peaks_[size_t(s->id)].load(std::memory_order_relaxed)) peaks_[size_t(s->id)].store(peak, std::memory_order_relaxed);
    pre_levels_[size_t(s->id)].store(float(std::sqrt(pre_energy / block_)), std::memory_order_relaxed);
    if (pre_peak > pre_peaks_[size_t(s->id)].load(std::memory_order_relaxed))
        pre_peaks_[size_t(s->id)].store(pre_peak, std::memory_order_relaxed);
    if (sending) {  // its sends: after its fader (and balance), or before it (muted with it); each held back to meet the rest
        const float muted = s->mute_gain * s->auto_mute * s->solo_gain;
        for (int k = 0; k < kMaxSends; ++k) {
            const auto& send = s->sends[size_t(k)];
            Source* aux = bus_at(send.bus);
            if (!aux) continue;
            if (send.pre) playSend(*s, k, *aux, s->pre.data(), s->pre_r.data(), muted, mute_coef);
            else playSend(*s, k, *aux, s->out_l.data(), s->out_r.data(), 1.0f, mute_coef);
        }
    }
    if (s->fade_blocks >= 0 && --s->fade_blocks < 0) {  // removed and faded out
        sources_[index] = nullptr;
        levels_[index].store(0.0f, std::memory_order_relaxed);
        peaks_[index].store(0.0f, std::memory_order_relaxed);
        pre_levels_[index].store(0.0f, std::memory_order_relaxed);
        pre_peaks_[index].store(0.0f, std::memory_order_relaxed);
        s->released.store(true, std::memory_order_release);
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
    std::fill(room_l_.begin(), room_l_.end(), 0.0f);
    std::fill(room_r_.begin(), room_r_.end(), 0.0f);
    std::fill(send_.begin(), send_.end(), 0.0f);
    std::fill(click_.begin(), click_.end(), 0.0f);
    sequencer_.process(clock_ + block_, *this);
    renderTimeline();
    if (sequencer_.running()) {  // the tracks' controls, as their automation has them
        const double at = sequencer_.position(clock_);
        for (Source* s : sources_)
            if (s && s->track_rt && s->read_params && !s->track_rt->automation.params.empty()) applyParams(*s, at);
    }
    const int64_t next_bar = sequencer_.nextBarAt(clock_);
    bar_timing_[0] = next_bar < 0 ? -1 : next_bar - clock_;
    bar_timing_[1] = int64_t(std::llround(sequencer_.barSamples()));
    for (auto& c : clicks_)
        if (c.active) for (int i = 0; i < block_ && c.active; ++i) click_[size_t(i)] += c.next();

    // The binaural rendering comes out a quarter of a block late. The click and the reverb's feed don't pass through
    // it, so while binaural is on they are held back by as much, to stay in step with the direct sound whatever the
    // block size. Switching it on or off moves over from one rendering (and its timing) to the other across a few
    // blocks, with what comes in meanwhile shared between the two.
    const float binaural_from = binaural_mix_;
    const float fade = float(block_) / (kBinauralFadeSeconds * float(sr_));
    binaural_mix_ = binaural_ ? std::min(binaural_mix_ + fade, 1.0f) : std::max(binaural_mix_ - fade, 0.0f);
    // The click, in step with what is heard: the room, as late as binaural rendering; the mix, as its compensation.
    const bool mix_heard = monitor_ == Monitor::Mix;
    click_delay_.process(click_.data(), block_, mix_heard ? 0.0f : binaural_from, mix_heard ? 0.0f : binaural_mix_);
    click_hold_.process(click_.data(), nullptr, block_, mix_heard ? click_compensation_ : 0);

    // Game updates arrive at frame rate; glide toward them so movement doesn't step (time constant ~15 ms).
    const float glide = 1.0f - std::exp(-float(block_) / (0.015f * float(sr_)));
    listener_pos_ = lerp(listener_pos_, target_pos_, glide);
    listener_ahead_ = normalized(lerp(listener_ahead_, target_ahead_, glide));
    listener_up_ = normalized(lerp(listener_up_, target_up_, glide));
    const float wall_glide = 1.0f - std::exp(-float(block_) / (0.05f * float(sr_)));
    falloff_ += (falloff_target_ - falloff_) * wall_glide;
    const float mute_coef = 1.0f - std::exp(-1.0f / (0.01f * float(sr_)));

    for (Source* s : sources_)
        if (s && isBus(s->kind)) {
            std::fill(s->bus_l.begin(), s->bus_l.end(), 0.0f);
            std::fill(s->bus_r.begin(), s->bus_r.end(), 0.0f);
        }
    for (size_t index = 0; index < sources_.size(); ++index)  // the room's sources (buses after the tracks that play
        if (sources_[index] && inRoom(sources_[index]->kind))     // into them, and microphones after what they hear)
            playSource(index, binaural_from, glide, wall_glide, mute_coef);
    playReflections(binaural_from);  // and their first reflections off the room's surfaces

    // The room's reverb, from what the sources fed it: for the listener, and for the microphones.
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

    // The microphones: what each hears of the room (recorded, if it is armed), then its track, as any track's.
    for (size_t index = 0; index < sources_.size(); ++index) {
        Source* mic = sources_[index];
        if (!mic || !isMic(mic->kind)) continue;
        const bool stereo = mic->capsule_count == 2;
        hearCapsule(*mic, 0, mic->mono.data(), reverb_level, wall_glide);
        if (stereo) hearCapsule(*mic, 1, mic->mono_r.data(), reverb_level, wall_glide);
        if (punching_ && mic->armed && recorder_rt_ && record_to_ > record_from_) {  // (a stereo mic's two, as one stereo file)
            const int slot = recorder_rt_->slotOf(mic->id), n = record_to_ - record_from_;
            if (stereo) recorder_rt_->write(slot, mic->mono.data() + record_from_, mic->mono_r.data() + record_from_, n);
            else recorder_rt_->write(slot, mic->mono.data() + record_from_, n);
        }
        if (!mic->hear_input) {
            std::copy(mic->playback.begin(), mic->playback.end(), mic->mono.begin());
            if (stereo) std::copy(mic->playback_r.begin(), mic->playback_r.end(), mic->mono_r.begin());
        }
        if (stereo) playStereoMic(index, wall_glide, mute_coef);
        else playSource(index, binaural_from, glide, wall_glide, mute_coef);
    }

    // The buses (folders and aux tracks), each after every bus that plays into it, by its output or a send: what reached
    // them, through their inserts (in two channels) and faders, to the master or the bus they are in, and their sends.
    // (The game refuses routing that would go round in a circle; were there one, its buses would still each play once.)
    auto bus_at = [&](int id) -> Source* {
        Source* b = id >= 0 && id < kSourceSlots ? sources_[size_t(id)] : nullptr;
        return b && isBus(b->kind) && !b->master_role ? b : nullptr;
    };
    std::array<int, kSourceSlots> order{}, waiting{};
    std::array<bool, kSourceSlots> placed{};
    int buses = 0;
    for (const Source* s : sources_) {
        if (!s || !isBus(s->kind) || s->master_role) continue;
        if (bus_at(s->output)) ++waiting[size_t(s->output)];
        for (const auto& send : s->sends)
            if (bus_at(send.bus)) ++waiting[size_t(send.bus)];
    }
    for (int i = 0; i < kSourceSlots; ++i)
        if (bus_at(i) && waiting[size_t(i)] == 0) {
            order[size_t(buses++)] = i;
            placed[size_t(i)] = true;
        }
    auto release = [&](int id) {
        if (bus_at(id) && --waiting[size_t(id)] <= 0 && !placed[size_t(id)]) {
            order[size_t(buses++)] = id;
            placed[size_t(id)] = true;
        }
    };
    for (int next = 0; next < buses; ++next) {
        const Source* b = sources_[size_t(order[size_t(next)])];
        release(b->output);
        for (const auto& send : b->sends) release(send.bus);
    }
    for (int i = 0; i < kSourceSlots; ++i)
        if (bus_at(i) && !placed[size_t(i)]) order[size_t(buses++)] = i;  // (a circle)

    for (int k = 0; k < buses; ++k) {
        const size_t index = size_t(order[size_t(k)]);
        Source* s = sources_[index];
        float* l = s->bus_l.data();
        float* r = s->bus_r.data();
        if (s->insert_board.count > 0) {
            const PedalTiming timing{double(bar_timing_[1]) / 4.0, bar_timing_[0], bar_timing_[1]};
            for (int p = 0; p < s->insert_board.count; ++p) s->insert_board.pedals[size_t(p)]->processStereo(l, r, block_, timing);
        }
        bool sending = false, sending_pre = false;
        for (const auto& send : s->sends)
            if (bus_at(send.bus) && (send.on || send.gain > 1e-6f)) {
                sending = true;
                sending_pre = sending_pre || send.pre;
            }
        Source* into = bus_at(s->output);
        float* to_l = into ? into->bus_l.data() : mix_l_.data();  // into the folder it is in, or the master
        float* to_r = into ? into->bus_r.data() : mix_r_.data();
        double energy = 0.0, pre_energy = 0.0;
        float peak = 0.0f, pre_peak = 0.0f;
        Automating automating(*this, *s);
        const float pan_from = s->pan;
        s->pan += (s->pan_target - s->pan) * wall_glide;
        for (int i = 0; i < block_; ++i) {
            pre_energy += 0.5 * (double(l[i]) * l[i] + double(r[i]) * r[i]);
            pre_peak = std::max(pre_peak, std::max(std::fabs(l[i]), std::fabs(r[i])));
            if (sending_pre) {  // (a bus keeps what reaches its fader where a track keeps its place in the room)
                s->out_l[size_t(i)] = l[i];
                s->out_r[size_t(i)] = r[i];
            }
            s->mute_gain += (s->mute_target - s->mute_gain) * mute_coef;
            automating.next(i, mute_coef);
            const float g = s->gain * s->mute_gain * s->auto_mute;
            l[i] *= g;
            r[i] *= g;
            // Its pan, after its fader: a mono folder's sound summed and placed as a mono track's (equal power, so the
            // middle of it keeps its level), a stereo one's balanced as a stereo track's (the other side turned down).
            const float pan = pan_from + (s->pan - pan_from) * float(i + 1) / float(block_);
            if (s->bus_mono) {
                const float m = (l[i] + r[i]) * kDryPan, angle = (pan + 1.0f) * 0.25f * float(kPi);
                l[i] = m * std::cos(angle);
                r[i] = m * std::sin(angle);
            } else if (pan != 0.0f) {
                if (pan > 0.0f) l[i] *= std::cos(pan * 0.5f * float(kPi));
                else r[i] *= std::cos(-pan * 0.5f * float(kPi));
            }
            energy += 0.5 * (double(l[i]) * l[i] + double(r[i]) * r[i]);
            peak = std::max(peak, std::max(std::fabs(l[i]), std::fabs(r[i])));
        }
        playOut(*s, l, r, to_l, to_r);
        if (sending) {  // its sends: after its fader, or before it (muted with it, as a track's); each held back to meet the rest
            const float muted = s->mute_gain * s->auto_mute;
            for (int k = 0; k < kMaxSends; ++k) {
                Source* aux = bus_at(s->sends[size_t(k)].bus);
                if (!aux) continue;
                if (s->sends[size_t(k)].pre) playSend(*s, k, *aux, s->out_l.data(), s->out_r.data(), muted, mute_coef);
                else playSend(*s, k, *aux, l, r, 1.0f, mute_coef);
            }
        }
        // Metered as it reaches the master, before the master fader: as dBFS.
        levels_[size_t(s->id)].store(float(std::sqrt(energy / block_)) * kMasterGain, std::memory_order_relaxed);
        if (peak * kMasterGain > peaks_[size_t(s->id)].load(std::memory_order_relaxed))
            peaks_[size_t(s->id)].store(peak * kMasterGain, std::memory_order_relaxed);
        pre_levels_[size_t(s->id)].store(float(std::sqrt(pre_energy / block_)) * kMasterGain, std::memory_order_relaxed);
        if (pre_peak * kMasterGain > pre_peaks_[size_t(s->id)].load(std::memory_order_relaxed))
            pre_peaks_[size_t(s->id)].store(pre_peak * kMasterGain, std::memory_order_relaxed);
        if (s->fade_blocks >= 0 && --s->fade_blocks < 0) {  // removed and faded out
            sources_[index] = nullptr;
            levels_[index].store(0.0f, std::memory_order_relaxed);
            peaks_[index].store(0.0f, std::memory_order_relaxed);
            pre_levels_[index].store(0.0f, std::memory_order_relaxed);
            pre_peaks_[index].store(0.0f, std::memory_order_relaxed);
            s->released.store(true, std::memory_order_release);
        }
    }

    const float slow = 1.0f - std::exp(-1.0f / (0.05f * float(sr_)));
    float reverb_peak_l = 0.0f, reverb_peak_r = 0.0f;
    double reverb_sq_l = 0.0, reverb_sq_r = 0.0;
    for (int i = 0; i < block_; ++i) {  // the room: its instruments, placed for your ears, and its reverb
        reverb_gain_ += (reverb_target_ - reverb_gain_) * slow;
        const float wet = reverb_level * reverb_gain_;
        const float back_l = rev_l_[size_t(i)] * wet * kMasterGain, back_r = rev_r_[size_t(i)] * wet * kMasterGain;  // its return, metered
        reverb_peak_l = std::max(reverb_peak_l, std::fabs(back_l));
        reverb_peak_r = std::max(reverb_peak_r, std::fabs(back_r));
        reverb_sq_l += double(back_l) * back_l;
        reverb_sq_r += double(back_r) * back_r;
        room_l_[size_t(i)] = (room_l_[size_t(i)] + rev_l_[size_t(i)] * wet) * kMasterGain;
        room_r_[size_t(i)] = (room_r_[size_t(i)] + rev_r_[size_t(i)] * wet) * kMasterGain;
        mix_l_[size_t(i)] *= kMasterGain;  // the mix: the tracks' outputs
        mix_r_[size_t(i)] *= kMasterGain;
    }
    // Each master, laid out as a DAW's master track: its inserts, then the fader, then the limiter (at the very end, as
    // an output limiter is: the fader brought down stops it working).
    for (const Monitor which : {Monitor::Mix, Monitor::Room}) {
        const int bus = master_bus_[size_t(which)];
        if (bus < 0 || !sources_[size_t(bus)]) continue;
        Source* master = sources_[size_t(bus)];
        float* l = which == Monitor::Mix ? mix_l_.data() : room_l_.data();
        float* r = which == Monitor::Mix ? mix_r_.data() : room_r_.data();
        const PedalTiming timing{double(bar_timing_[1]) / 4.0, bar_timing_[0], bar_timing_[1]};
        for (int p = 0; p < master->insert_board.count; ++p) master->insert_board.pedals[size_t(p)]->processStereo(l, r, block_, timing);
    }
    // The master faders: as set, or while the music plays, as their automation has them (glided every 32 samples).
    const auto automated = [&](Monitor which) {
        const size_t m = size_t(which);
        return sequencer_.running() && master_read_[m] && master_auto_rt_[m] && !master_auto_rt_[m]->empty();
    };
    const bool mix_automated = automated(Monitor::Mix), room_automated = automated(Monitor::Room);
    float mix_ramp = 0.0f, room_ramp = 0.0f;
    for (int i = 0; i < block_; ++i) {
        if (i % Automating::kEvery == 0) {
            const int chunk = std::min(Automating::kEvery, block_ - i);
            const double ahead = sequencer_.position(clock_ + i + chunk);
            if (mix_automated) mix_ramp = (gainOf(rampAt(*master_auto_rt_[size_t(Monitor::Mix)], ahead)) - master_gain_) / float(chunk);
            if (room_automated) room_ramp = (gainOf(rampAt(*master_auto_rt_[size_t(Monitor::Room)], ahead)) - room_volume_) / float(chunk);
        }
        if (mix_automated) master_gain_ += mix_ramp;
        else master_gain_ += (master_target_ - master_gain_) * slow;
        if (room_automated) room_volume_ += room_ramp;
        else room_volume_ += (room_target_ - room_volume_) * slow;
        mix_l_[size_t(i)] *= master_gain_;
        mix_r_[size_t(i)] *= master_gain_;
        room_l_[size_t(i)] *= room_volume_;
        room_r_[size_t(i)] *= room_volume_;
    }
    float lowest = 1.0f;
    if (limiter_on_[size_t(Monitor::Mix)]) lowest = std::min(lowest, limiter_.process(mix_l_.data(), mix_r_.data(), block_));
    if (limiter_on_[size_t(Monitor::Room)]) lowest = std::min(lowest, room_limiter_.process(room_l_.data(), room_r_.data(), block_));
    if (lowest < meter_gain_.load(std::memory_order_relaxed)) meter_gain_.store(lowest, std::memory_order_relaxed);
    // Each mix metered as it leaves its master; the main outputs play the one monitored (and the click, which is for the
    // player, not part of either), and whatever they play over full scale is cut off and counted. Each also goes to
    // its own outputs, if it has some.
    auto meter = [&](const std::vector<float>& l, const std::vector<float>& r, std::atomic<float>& peak_l, std::atomic<float>& peak_r,
                     float& ms_l, float& ms_r, std::atomic<float>& rms_l, std::atomic<float>& rms_r) {
        float pl = 0.0f, pr = 0.0f;
        double sl = 0.0, sq = 0.0;
        for (int i = 0; i < block_; ++i) {
            pl = std::max(pl, std::fabs(l[size_t(i)]));
            pr = std::max(pr, std::fabs(r[size_t(i)]));
            sl += double(l[size_t(i)]) * l[size_t(i)];
            sq += double(r[size_t(i)]) * r[size_t(i)];
        }
        if (pl > peak_l.load(std::memory_order_relaxed)) peak_l.store(pl, std::memory_order_relaxed);
        if (pr > peak_r.load(std::memory_order_relaxed)) peak_r.store(pr, std::memory_order_relaxed);
        const float settle = std::exp(-float(block_) / (0.3f * float(sr_)));
        ms_l = ms_l * settle + float(sl / block_) * (1.0f - settle);
        ms_r = ms_r * settle + float(sq / block_) * (1.0f - settle);
        rms_l.store(std::sqrt(ms_l), std::memory_order_relaxed);
        rms_r.store(std::sqrt(ms_r), std::memory_order_relaxed);
    };
    meter(room_l_, room_r_, room_peak_l_, room_peak_r_, room_ms_l_, room_ms_r_, room_rms_l_, room_rms_r_);
    meter(mix_l_, mix_r_, mix_peak_l_, mix_peak_r_, mix_ms_l_, mix_ms_r_, mix_rms_l_, mix_rms_r_);
    const std::vector<float>& heard_l = monitor_ == Monitor::Mix ? mix_l_ : room_l_;
    const std::vector<float>& heard_r = monitor_ == Monitor::Mix ? mix_r_ : room_r_;
    uint32_t clipped = 0;
    for (int i = 0; i < block_; ++i) {
        const float c = click_[size_t(i)] * kMasterGain;
        out_l_[size_t(i)] = heard_l[size_t(i)] + c;
        out_r_[size_t(i)] = heard_r[size_t(i)] + c;
        mix_tap_l_[size_t(i)] = std::clamp(mix_l_[size_t(i)], -1.0f, 1.0f);
        mix_tap_r_[size_t(i)] = std::clamp(mix_r_[size_t(i)], -1.0f, 1.0f);
        room_tap_l_[size_t(i)] = std::clamp(room_l_[size_t(i)], -1.0f, 1.0f);
        room_tap_r_[size_t(i)] = std::clamp(room_r_[size_t(i)], -1.0f, 1.0f);
        for (float* v : {&out_l_[size_t(i)], &out_r_[size_t(i)]}) {
            if (std::fabs(*v) > 1.0f) {
                *v = std::copysign(1.0f, *v);
                ++clipped;
            }
        }
    }
    if (clipped) meter_clipped_.fetch_add(clipped, std::memory_order_relaxed);
    // The meter reads what leaves for the sound card.
    float peak_l = 0.0f, peak_r = 0.0f;
    double square_l = 0.0, square_r = 0.0;
    for (int i = 0; i < block_; ++i) {
        peak_l = std::max(peak_l, std::fabs(out_l_[size_t(i)]));
        peak_r = std::max(peak_r, std::fabs(out_r_[size_t(i)]));
        square_l += double(out_l_[size_t(i)]) * out_l_[size_t(i)];
        square_r += double(out_r_[size_t(i)]) * out_r_[size_t(i)];
    }
    if (reverb_peak_l > reverb_peak_l_.load(std::memory_order_relaxed)) reverb_peak_l_.store(reverb_peak_l, std::memory_order_relaxed);
    if (reverb_peak_r > reverb_peak_r_.load(std::memory_order_relaxed)) reverb_peak_r_.store(reverb_peak_r, std::memory_order_relaxed);
    {
        const float settle_reverb = std::exp(-float(block_) / (0.3f * float(sr_)));
        reverb_ms_l_ = reverb_ms_l_ * settle_reverb + float(reverb_sq_l / block_) * (1.0f - settle_reverb);
        reverb_ms_r_ = reverb_ms_r_ * settle_reverb + float(reverb_sq_r / block_) * (1.0f - settle_reverb);
        reverb_rms_l_.store(std::sqrt(reverb_ms_l_), std::memory_order_relaxed);
        reverb_rms_r_.store(std::sqrt(reverb_ms_r_), std::memory_order_relaxed);
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
    streamer_.blockDone();  // (the chunks this block read may be let go of now)
}

}  // namespace sr
