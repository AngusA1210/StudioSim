// Offline checks for the audio core: renders the prototype's room without a sound card and measures it.
// Run: build/engine_tests            (exit code 0 = all checks passed)
//      build/engine_tests --dump file [old-levels]
//                                    (writes what the default room plays, to compare before and after a change)
//      build/engine_tests --paths in out  (the wall model's answers for the listener and source positions in `in`)
//      build/engine_tests --device ["name" [buffer [left right]]]
//                                    (lists audio devices, opens one silently, prints its latency)
//      build/engine_tests --midi     (lists MIDI devices and reports the notes they send for 15 seconds)
//      build/engine_tests --plugins  (lists the effect plug-ins installed, with what kind each seems to be)

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <iterator>
#include <tuple>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

#include "acoustics.h"
#include "amp.h"
#include "engine.h"
#include "looper.h"
#include "pedals.h"
#include "plugin_host.h"
#include "room_geometry.h"

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>
#endif

using namespace sr;

namespace {

int failures = 0;

void check(bool ok, const std::string& what, const std::string& detail) {
    std::printf("  [%s] %s  (%s)\n", ok ? "pass" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++failures;
}

std::string fmt(const char* f, double a, double b = 0, double c = 0) {
    char buf[256];
    std::snprintf(buf, sizeof(buf), f, a, b, c);
    return buf;
}

double db(double x) { return 20.0 * std::log10(x + 1e-12); }

struct Render {
    std::vector<float> l, r;
    double rms_l = 0, rms_r = 0, peak = 0;
    bool finite = true;
};

// `input`, if given, supplies the captured (mono) audio for each frame index.
Render renderSeconds(AudioEngine& e, double seconds, const std::function<float(int64_t)>& input = {}) {
    const int block = e.blockSize();
    const int64_t frames = int64_t(seconds * e.sampleRate()) / block * block;
    std::vector<float> buf(size_t(block) * 2), in(static_cast<size_t>(block));
    Render out;
    double el = 0, er = 0;
    for (int64_t f = 0; f < frames; f += block) {
        if (input) {
            for (int i = 0; i < block; ++i) in[size_t(i)] = input(f + i);
            e.render(in.data(), buf.data(), block);
        } else {
            e.render(buf.data(), block);
        }
        for (int i = 0; i < block; ++i) {
            const float a = buf[size_t(2 * i)], b = buf[size_t(2 * i + 1)];
            if (!std::isfinite(a) || !std::isfinite(b)) out.finite = false;
            out.l.push_back(a);
            out.r.push_back(b);
            el += double(a) * a;
            er += double(b) * b;
            out.peak = std::max(out.peak, double(std::max(std::fabs(a), std::fabs(b))));
        }
    }
    out.rms_l = std::sqrt(el / double(frames));
    out.rms_r = std::sqrt(er / double(frames));
    return out;
}

int firstSound(const Render& r) {  // the first sample above -100 dBFS
    for (size_t i = 0; i < r.l.size(); ++i)
        if (std::fabs(r.l[i]) > 1e-5f || std::fabs(r.r[i]) > 1e-5f) return int(i);
    return -1;
}

// Where a sound starts: the first sample to reach a quarter of the loudest, looking from `from` on.
int onsetAfter(const std::vector<float>& x, size_t from) {
    double peak = 0;
    for (size_t i = from; i < x.size(); ++i) peak = std::max(peak, double(std::fabs(x[i])));
    for (size_t i = from; i < x.size(); ++i)
        if (std::fabs(x[i]) > 0.25 * peak) return int(i);
    return -1;
}

// The biggest jump from one sample to the next, in either ear: a click shows up as one far bigger than the music's.
double biggestStep(const Render& r) {
    double step = 0;
    for (size_t i = 1; i < r.l.size(); ++i)
        step = std::max(step, double(std::max(std::fabs(r.l[i] - r.l[i - 1]), std::fabs(r.r[i] - r.r[i - 1]))));
    return step;
}

double tailPeak(const Render& r, size_t samples) {
    double peak = 0;
    for (size_t i = r.l.size() - samples; i < r.l.size(); ++i) peak = std::max(peak, double(std::fabs(r.l[i])));
    return peak;
}

// Sample positions where a sound starts: the level passes a tenth of the peak after `quiet` samples below it.
std::vector<int> onsets(const Render& r, int quiet) {
    std::vector<int> out;
    const double threshold = 0.1 * r.peak;
    int below = quiet;
    for (size_t i = 0; i < r.l.size(); ++i) {
        const bool loud = std::max(std::fabs(r.l[i]), std::fabs(r.r[i])) > threshold;
        if (loud && below >= quiet) out.push_back(int(i));
        below = loud ? 0 : below + 1;
    }
    return out;
}

// Whether every gap between onsets (from the `from`th on) is `expected` samples, give or take a millisecond.
bool spaced(const std::vector<int>& on, size_t from, int expected, std::string& detail) {
    bool ok = on.size() >= from + 3;
    detail = fmt("%.0f onsets, gaps in samples:", double(on.size()));
    for (size_t i = from + 1; i < on.size(); ++i) {
        const int gap = on[i] - on[i - 1];
        if (std::abs(gap - expected) > 48) ok = false;
        if (i < from + 5) detail += fmt(" %.0f", gap);
    }
    return ok;
}

double level(const Render& r) { return db(std::sqrt((r.rms_l * r.rms_l + r.rms_r * r.rms_r) / 2)); }

int crossings(const Render& r, int from, int count) {
    int n = 0;
    for (int i = from + 1; i < from + count && i < int(r.l.size()); ++i)
        if ((r.l[size_t(i)] >= 0) != (r.l[size_t(i - 1)] >= 0)) ++n;
    return n;
}

// How strong frequency `hz` is in `x` (Goertzel), as power.
double tonePower(const std::vector<float>& x, double hz, double sr) {
    const double w = 2.0 * 3.14159265358979 * hz / sr, c = 2.0 * std::cos(w);
    double s1 = 0, s2 = 0;
    for (float v : x) {
        const double s0 = v + c * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return (s1 * s1 + s2 * s2 - c * s1 * s2) / double(x.size() * x.size());
}

// A plucked string (Karplus-Strong), as a guitar or bass plugged straight into an interface sounds before an amp.
std::vector<float> pluckedString(double hz, double seconds, float level, double sr = 48000.0) {
    std::vector<float> out(size_t(seconds * sr));
    Rng rng;
    for (size_t start = 0; start < out.size(); start += size_t(sr / 2)) {  // a note every half second
        std::vector<float> line(size_t(sr / hz));
        for (float& v : line) v = rng.next();
        size_t at = 0;
        for (size_t i = start; i < out.size() && i < start + size_t(sr / 2); ++i) {
            const size_t next = (at + 1) % line.size();
            const float y = 0.498f * (line[at] + line[next]);
            out[i] += line[at];
            line[at] = y;
            at = next;
        }
    }
    double energy = 0;
    for (float v : out) energy += double(v) * v;
    const float scale = level / float(std::sqrt(energy / double(out.size())));
    for (float& v : out) v *= scale;
    return out;
}

// The prototype's room: same instruments, positions, levels and reverb sends, plus a speaker for live input.
// Every instrument starts with its part of the default groove.
struct Room {
    AudioEngine engine;
    int drums, bass, pad, bells, keys, speaker;
    Room() {
        std::string err;
        if (!engine.init(&err)) {
            std::printf("init failed: %s\n", err.c_str());
            std::exit(2);
        }
        drums = engine.addSource(InstrumentKind::Drums, {0.5f, 0.9f, -3.6f}, 0.50f, 0.6f);
        bass = engine.addSource(InstrumentKind::Bass, {-5.0f, 1.0f, -2.0f}, 0.38f, 0.4f);
        pad = engine.addSource(InstrumentKind::Pad, {4.8f, 1.6f, -1.6f}, 1.00f, 1.0f);
        bells = engine.addSource(InstrumentKind::Bells, {-4.6f, 1.6f, 2.4f}, 0.42f, 1.0f);
        keys = engine.addSource(InstrumentKind::Keys, {3.0f, 0.95f, 1.8f}, 0.20f, 0.9f);
        speaker = engine.addSource(InstrumentKind::Live, {-1.5f, 0.8f, 2.6f}, 1.0f, 0.7f);
        for (int s : {drums, bass, pad, bells, keys}) engine.loadDefaultPattern(s);
        face(0.0f, 3.6f, 0.0f);
    }
    // yaw 0 faces -z (north); positive yaw turns left
    void face(float x, float z, float yaw) {
        engine.setListener({x, 1.65f, z}, {-std::sin(yaw), 0, -std::cos(yaw)}, {0, 1, 0});
    }
    void soloOnly(int id) {
        for (int s : {drums, bass, pad, bells, keys, speaker}) engine.setSourceMuted(s, s != id);
    }
    void quietRoom(int solo) {  // one source, no groove, no reverb
        soloOnly(solo);
        engine.setReverb(false);
        engine.setSequencerRunning(false);
    }
};

// Energy below 300 Hz and above 4 kHz, using steep (4th-order) filters so the bands don't leak.
void bandEnergy(const std::vector<float>& x, float sr, double& low, double& high) {
    Biquad lp[2], hp[2];
    for (auto& f : lp) f.set(Biquad::Lowpass, sr, 300.0f, 0.707f);
    for (auto& f : hp) f.set(Biquad::Highpass, sr, 4000.0f, 0.707f);
    low = high = 0;
    for (float v : x) {
        const float a = lp[1].process(lp[0].process(v)), b = hp[1].process(hp[0].process(v));
        low += double(a) * a;
        high += double(b) * b;
    }
}

#ifdef __APPLE__
// A pretend MIDI keyboard: a virtual CoreMIDI source the engine sees like any plugged-in controller.
struct VirtualKeyboard {
    MIDIClientRef client = 0;
    MIDIEndpointRef source = 0;
    bool open(CFStringRef name) {
        return MIDIClientCreate(CFSTR("SoundRoom Tests"), nullptr, nullptr, &client) == noErr &&
               MIDISourceCreateWithProtocol(client, name, kMIDIProtocol_1_0, &source) == noErr;
    }
    void send(uint8_t status, uint8_t d1, uint8_t d2) const {
        MIDIEventList list;
        MIDIEventPacket* packet = MIDIEventListInit(&list, kMIDIProtocol_1_0);
        const UInt32 word = (0x2u << 28) | (uint32_t(status) << 16) | (uint32_t(d1) << 8) | d2;
        MIDIEventListAdd(&list, sizeof(list), packet, 0, 1, &word);
        MIDIReceivedEventList(source, &list);
        std::this_thread::sleep_for(std::chrono::milliseconds(60));  // let the MIDI thread deliver it
    }
    ~VirtualKeyboard() {
        if (source) MIDIEndpointDispose(source);
        if (client) MIDIClientDispose(client);
    }
};
#endif

}  // namespace

// Lists the audio devices, then opens the default output with no sources (so it plays silence) and reports what
// the OS says about latency.
int deviceProbe(const DeviceConfig& config) {
    for (const auto& d : AudioEngine::outputDevices())
        std::printf("output: %-32s %2d ch%s\n", d.name.c_str(), d.channels, d.is_default ? "  (default)" : "");
    for (const auto& d : AudioEngine::inputDevices())
        std::printf("input:  %-32s %2d ch%s\n", d.name.c_str(), d.channels, d.is_default ? "  (default)" : "");
    AudioEngine engine;
    std::string err;
    if (!engine.init(&err) || !engine.openDevice(config, &err)) {
        std::printf("device probe failed: %s\n", err.c_str());
        return 1;
    }
    std::this_thread::sleep_for(std::chrono::seconds(1));
    const EngineStats s = engine.stats();
    std::printf("opened %s via %s: %d Hz, %d outputs, buffer %d frames\n", s.output_device.c_str(), s.backend.c_str(),
                s.sample_rate, s.output_channels, s.device_period);
    std::printf("mix on outputs %d and %d; engine block %d frames\n", engine.deviceConfig().output_left + 1,
                engine.deviceConfig().output_right + 1, engine.blockSize());
    std::printf("buffer %.2f ms + device %.2f ms + binaural %.2f ms = output latency %.2f ms; %llu blocks rendered\n", s.buffer_ms,
                s.device_ms, s.binaural_ms, s.output_latency_ms, (unsigned long long)s.blocks);
    return s.blocks > 0 ? 0 : 1;
}

// Lists MIDI devices and reports whatever they send for a while. Play some notes while it runs.
int midiProbe(int seconds) {
    AudioEngine engine;
    std::string err;
    if (!engine.init(&err) || !engine.startMidi(&err)) {
        std::printf("midi probe failed: %s\n", err.c_str());
        return 1;
    }
    std::vector<uint32_t> seen;
    std::printf("Listening for %d seconds. Play some notes.\n", seconds);
    for (int tick = 0; tick < seconds * 10; ++tick) {
#ifdef __APPLE__
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
#else
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
#endif
        if (tick % 10 == 0) engine.pollMidi();
        const auto devices = engine.midiDevices();
        if (devices.size() != seen.size()) {
            seen.assign(devices.size(), 0);
            std::printf("%zu MIDI device(s):\n", devices.size());
            for (const auto& d : devices) std::printf("  %s\n", d.name.c_str());
        }
        for (size_t i = 0; i < devices.size(); ++i) {
            if (devices[i].events != seen[i]) {
                std::printf("  %s sent %u event(s)\n", devices[i].name.c_str(), devices[i].events - seen[i]);
                seen[i] = devices[i].events;
            }
        }
        std::fflush(stdout);
    }
    return 0;
}

// The engine's levels as they were before the output was lowered to leave headroom close up: the master volume
// brought back up by as much.
void oldLevels(AudioEngine& engine) {
    engine.setDistanceFalloff(6.0f);
    engine.setMasterVolume(std::sqrt(7.0f / 1.5f));
}

// Writes what the default room plays to a file of raw 32-bit floats (interleaved stereo): two loops of the full
// mix, then one loop of each sequenced instrument alone with the reverb off. Comparing two dumps shows whether a
// change to the engine altered the sound. With `old_levels`, the engine is first set to the levels it had before
// the distance falloff became adjustable, to compare with dumps from then.
int dumpGroove(const char* path, bool old_levels) {
    std::FILE* file = std::fopen(path, "wb");
    if (!file) {
        std::printf("could not write %s\n", path);
        return 1;
    }
    auto write = [&](const Render& r) {
        for (size_t i = 0; i < r.l.size(); ++i) {
            const float frame[2] = {r.l[i], r.r[i]};
            std::fwrite(frame, sizeof(float), 2, file);
        }
    };
    {
        Room room;
        if (old_levels) oldLevels(room.engine);
        write(renderSeconds(room.engine, 20.86));
    }
    for (int which = 0; which < 4; ++which) {
        Room room;
        if (old_levels) oldLevels(room.engine);
        const int ids[4] = {room.drums, room.bass, room.pad, room.bells};
        room.soloOnly(ids[which]);
        room.engine.setReverb(false);
        write(renderSeconds(room.engine, 10.43));
    }
    std::fclose(file);
    return 0;
}

// Reads lines that begin with a listener and a source position and writes, for each, how the default room's one
// wall changes the route between them. A way to compare the wall model before and after a change to it.
int dumpPaths(const char* in_path, const char* out_path) {
    std::FILE* in = std::fopen(in_path, "r");
    std::FILE* out = std::fopen(out_path, "w");
    if (!in || !out) return 1;
    RoomGeometry geometry;
    geometry.setRoom(14.0f, 10.0f, 4.0f, {{-2.5f, -3.25f, -2.5f, -0.55f, 0.3f, 3.0f}});
    char line[512];
    while (std::fgets(line, sizeof(line), in)) {
        float e[3], s[3];
        if (std::sscanf(line, "%f %f %f %f %f %f", &e[0], &e[1], &e[2], &s[0], &s[1], &s[2]) != 6) continue;
        const DirectPath p = geometry.directPath({e[0], e[1], e[2]}, {s[0], s[1], s[2]});
        std::fprintf(out, "%.4f %.4f %.4f %.4f %.4f %.4f %d %.5f %.5f %.5f %.5f %d", e[0], e[1], e[2], s[0], s[1], s[2], p.blocked ? 1 : 0,
                     p.via.x, p.via.y, p.via.z, p.extra, p.count);
        for (int i = 0; i < p.count; ++i) std::fprintf(out, " %.5f", p.differences[i]);
        std::fprintf(out, "\n");
    }
    std::fclose(in);
    std::fclose(out);
    return 0;
}

int main(int argc, char** argv) {
    if (argc > 2 && std::string(argv[1]) == "--dump") return dumpGroove(argv[2], argc > 3 && std::string(argv[3]) == "old-levels");
    if (argc > 3 && std::string(argv[1]) == "--paths") return dumpPaths(argv[2], argv[3]);
    if (argc > 1 && std::string(argv[1]) == "--device") {  // --device ["name" [buffer [left right]]]
        DeviceConfig config;
        if (argc > 2) config.output_device = argv[2];
        if (argc > 3) config.buffer_size = std::atoi(argv[3]);
        if (argc > 5) { config.output_left = std::atoi(argv[4]) - 1; config.output_right = std::atoi(argv[5]) - 1; }
        return deviceProbe(config);
    }
    if (argc > 1 && std::string(argv[1]) == "--midi") return midiProbe(argc > 2 ? std::atoi(argv[2]) : 15);
    if (argc > 1 && std::string(argv[1]) == "--plugins") {
        for (const PluginDescription& p : PluginInstance::available())
            std::printf("%-26s %-34s %s\n", p.category.c_str(), p.name.c_str(), p.maker.c_str());
        return 0;
    }
    std::printf("SoundRoom audio core: offline checks\n");

    {
        std::printf("\nThe room at the spawn point\n");
        Room room;
        const auto t0 = std::chrono::steady_clock::now();
        Render r = renderSeconds(room.engine, 10.43);  // one full four-bar loop
        const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        check(r.finite, "output is finite", "no NaN or infinity");
        check(r.peak < 1.0, "no clipping", fmt("peak %.1f dBFS", db(r.peak)));
        const double rms = std::sqrt((r.rms_l * r.rms_l + r.rms_r * r.rms_r) / 2);
        check(rms > 0.025 && rms < 0.06 && r.peak < 0.4, "a moderate level, with headroom to spare",
              fmt("%.1f dBFS RMS (L %.1f, R %.1f)", db(rms), db(r.rms_l), db(r.rms_r)) + fmt(", peaks %.1f dBFS", db(r.peak)));
        check(secs < 10.43 / 4, "renders well faster than real time", fmt("%.1fx real time", 10.43 / secs));
    }

    {
        std::printf("\nBinaural direction (bells alone, reverb off)\n");
        Room room;
        room.soloOnly(room.bells);
        room.engine.setReverb(false);
        renderSeconds(room.engine, 0.5);
        auto lr = [&](float yaw) {
            room.face(0.0f, 3.6f, yaw);
            renderSeconds(room.engine, 0.2);
            Render r = renderSeconds(room.engine, 5.2);
            return db(r.rms_l) - db(r.rms_r);
        };
        const double north = lr(0.0f), south = lr(3.14159f), facing = lr(1.31f);
        check(north > 3.0, "bells 75° to the left are louder in the left ear", fmt("L-R %+.1f dB", north));
        check(south < -3.0, "turning around moves them to the right ear", fmt("L-R %+.1f dB", south));
        check(std::fabs(facing) < 2.0, "facing them, both ears match", fmt("L-R %+.1f dB", facing));
    }

    {
        std::printf("\nSound bending around a wall\n");
        const double clear = db(barrierGain(-1.0f, 2500.0f));
        const double edge_low = db(barrierGain(0.0f, 300.0f)), edge_high = db(barrierGain(0.0f, 12000.0f));
        check(std::fabs(clear) < 0.01, "a clear line of sight loses nothing", fmt("%.2f dB", clear));
        check(std::fabs(edge_low + 4.77) < 0.1 && std::fabs(edge_high + 4.77) < 0.1, "at the shadow edge every band is down about 5 dB",
              fmt("lows %.1f dB, highs %.1f dB", edge_low, edge_high));
        const double deep_low = db(barrierGain(0.3f, 300.0f)), deep_mid = db(barrierGain(0.3f, 2500.0f)),
                     deep_high = db(barrierGain(0.3f, 12000.0f));
        check(deep_low > deep_mid && deep_mid > deep_high && deep_high >= -24.01,
              "deeper in the shadow, highs lose more than lows", fmt("lows %.1f, mids %.1f, highs %.1f dB", deep_low, deep_mid, deep_high));

        // Rendered: drums heard directly, then by a 0.3 m longer route around a wall edge.
        Room room;
        room.soloOnly(room.drums);
        room.engine.setReverb(false);
        room.face(0.0f, -1.0f, 0.0f);
        renderSeconds(room.engine, 0.5);
        Render open = renderSeconds(room.engine, 10.43);
        const float delta[1] = {0.3f};
        room.engine.setSourceDirectPath(room.drums, {0.5f, 0.9f, -3.6f}, 0.0f, delta, 1, true);
        renderSeconds(room.engine, 0.5);
        Render shadowed = renderSeconds(room.engine, 10.43);
        double ol, oh, sl, sh;
        bandEnergy(open.l, 48000.0f, ol, oh);
        bandEnergy(shadowed.l, 48000.0f, sl, sh);
        const double low_drop = 10 * std::log10(ol / sl), high_drop = 10 * std::log10(oh / sh);
        check(low_drop > 3.0 && low_drop < 13.0 && high_drop > low_drop + 6.0, "rendered audio shows the same: dull but not gone",
              fmt("kick (lows) down %.1f dB, hats (highs) down %.1f dB", low_drop, high_drop));

        // The bells are really on the left, but their sound reaches us around an edge on the right.
        Room bent;
        bent.soloOnly(bent.bells);
        bent.engine.setReverb(false);
        bent.face(0.0f, 3.6f, 0.0f);
        const float around[1] = {0.05f};
        bent.engine.setSourceDirectPath(bent.bells, {3.0f, 1.65f, 3.6f}, 6.0f, around, 1, true);
        renderSeconds(bent.engine, 0.5);
        Render r = renderSeconds(bent.engine, 5.2);
        check(db(r.rms_l) - db(r.rms_r) < -3.0, "the sound arrives from the edge it bends around, not through the wall",
              fmt("L-R %+.1f dB with the edge on the right", db(r.rms_l) - db(r.rms_r)));
    }

    {
        std::printf("\nKeys latency (keys alone)\n");
        Room room;
        room.quietRoom(room.keys);
        room.face(3.0f, 3.0f, 0.0f);
        renderSeconds(room.engine, 0.3);
        const int block = room.engine.blockSize();
        room.engine.noteOn(room.keys, 60, 0.8f);
        Render r = renderSeconds(room.engine, 0.05);
        const int first = firstSound(r);
        check(first >= 0 && first < block, "a note sounds in the very next block",
              fmt("first sample after %.2f ms (block is %.2f ms)", first * 1000.0 / 48000.0, block * 1000.0 / 48000.0));
        room.engine.noteOff(room.keys, 60);
        Render tail = renderSeconds(room.engine, 1.0);
        check(tailPeak(tail, 4800) < 1e-3, "note-off releases the note", fmt("last 100 ms peak %.1f dBFS", db(tailPeak(tail, 4800))));
    }

#ifdef __APPLE__
    {
        std::printf("\nMIDI controller (a virtual keyboard)\n");
        VirtualKeyboard keyboard;
        if (!keyboard.open(CFSTR("SoundRoom Test Keyboard"))) {
            std::printf("  [skip] the system MIDI service is not available here\n");
        } else {
            Room room;
            room.quietRoom(room.keys);
            room.face(3.0f, 3.0f, 0.0f);
            std::string err;
            const bool started = room.engine.startMidi(&err);
            auto names = room.engine.midiDevices();
            std::string keyboard_name;
            for (const auto& d : names)
                if (d.name.find("SoundRoom Test Keyboard") != std::string::npos) keyboard_name = d.name;
            check(started && !keyboard_name.empty(), "the engine finds the keyboard", fmt("%.0f MIDI source(s) listed", double(names.size())));

            renderSeconds(room.engine, 0.3);
            keyboard.send(0x90, 62, 100);
            Render nobody = renderSeconds(room.engine, 0.3);
            keyboard.send(0x80, 62, 0);
            check(nobody.peak < 1e-5, "with no instrument's input on, the controller plays nothing", fmt("peak %.0f dBFS", db(nobody.peak)));

            room.engine.setSourceInput(room.keys, true);  // the player sits down at the Keys
            keyboard.send(0x90, 60, 100);  // note on, middle C
            Render on = renderSeconds(room.engine, 0.3);
            check(firstSound(on) >= 0 && firstSound(on) < room.engine.blockSize(), "a key press sounds in the next block",
                  fmt("first sample after %.2f ms", firstSound(on) * 1000.0 / 48000.0));

            keyboard.send(0xB0, 64, 127);  // sustain pedal down
            keyboard.send(0x80, 60, 0);    // key up
            Render held = renderSeconds(room.engine, 0.6);
            check(tailPeak(held, 4800) > 3e-3, "the sustain pedal keeps the note ringing after the key is released",
                  fmt("still at %.1f dBFS", db(tailPeak(held, 4800))));
            keyboard.send(0xB0, 64, 0);    // pedal up
            Render released = renderSeconds(room.engine, 1.0);
            check(tailPeak(released, 4800) < 1e-3, "lifting the pedal releases it", fmt("%.1f dBFS", db(tailPeak(released, 4800))));

            room.engine.setMidiDeviceEnabled(keyboard_name, false);
            keyboard.send(0x90, 64, 100);
            Render ignored = renderSeconds(room.engine, 0.3);
            keyboard.send(0x80, 64, 0);
            room.engine.setMidiDeviceEnabled(keyboard_name, true);
            keyboard.send(0x90, 67, 100);
            Render heard = renderSeconds(room.engine, 0.3);
            keyboard.send(0x80, 67, 0);
            check(ignored.peak < 1e-4 && heard.peak > 1e-2, "a device can be switched off and back on",
                  fmt("off: %.0f dBFS, on: %.0f dBFS", db(ignored.peak), db(heard.peak)));

            // The controller plays whichever instruments have their input on.
            renderSeconds(room.engine, 1.0);
            room.engine.setSourceMuted(room.drums, false);
            room.engine.setSourceMuted(room.bass, false);
            room.engine.setSourceInput(room.keys, false);
            room.engine.setSourceInput(room.drums, true);
            keyboard.send(0x90, 36, 110);  // the kick on a General MIDI drum map
            renderSeconds(room.engine, 0.02);
            const double drums_level = room.engine.sourceLevel(room.drums), keys_level = room.engine.sourceLevel(room.keys);
            keyboard.send(0x80, 36, 0);
            check(drums_level > 1e-3 && keys_level < 1e-5, "with the drums' input on instead, the controller plays the drums and not the Keys",
                  fmt("drums %.0f dBFS, keys %.0f dBFS", db(drums_level), db(keys_level)));
            room.engine.setSourceInput(room.drums, false);
            room.engine.setSourceInput(room.bass, true);
            keyboard.send(0x90, 40, 100);
            renderSeconds(room.engine, 0.5);
            const double held_bass = room.engine.sourceLevel(room.bass);
            room.engine.setSourceInput(room.bass, false);  // switched off with the key still down
            renderSeconds(room.engine, 0.3);
            const double left_bass = room.engine.sourceLevel(room.bass);
            keyboard.send(0x80, 40, 0);
            check(held_bass > 1e-3 && left_bass < 1e-4, "a held bass note sustains, and switching its input off lets it go",
                  fmt("held %.0f dBFS, after switching off %.0f dBFS", db(held_bass), db(left_bass)));
            room.engine.setSourceMuted(room.keys, false);
            room.engine.setSourceInput(room.keys, true);
            room.engine.setSourceInput(room.bass, true);
            renderSeconds(room.engine, 0.5);
            keyboard.send(0x90, 45, 100);
            renderSeconds(room.engine, 0.1);
            const double layered_keys = room.engine.sourceLevel(room.keys), layered_bass = room.engine.sourceLevel(room.bass);
            keyboard.send(0x80, 45, 0);
            room.engine.setSourceInput(room.keys, false);
            room.engine.setSourceInput(room.bass, false);
            check(layered_keys > 1e-3 && layered_bass > 1e-3, "with two inputs on, one keyboard plays both instruments at once",
                  fmt("keys %.0f dBFS, bass %.0f dBFS", db(layered_keys), db(layered_bass)));

            VirtualKeyboard second;  // plugged in while running
            second.open(CFSTR("SoundRoom Second Keyboard"));
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
            room.engine.pollMidi();
            check(room.engine.midiDevices().size() == names.size() + 1, "a controller plugged in later is picked up",
                  fmt("%.0f sources now", double(room.engine.midiDevices().size())));
        }
    }
#endif

    {
        std::printf("\nLive input (a test tone standing in for a microphone)\n");
        Room room;
        room.quietRoom(room.speaker);
        room.face(-1.5f, 4.2f, 0.0f);  // facing the speaker from 1.6 m
        auto tone = [](int64_t n) { return 0.25f * float(std::sin(6.2831853 * 440.0 * double(n) / 48000.0)); };
        Render input_off = renderSeconds(room.engine, 0.5, tone);
        check(input_off.peak < 1e-5, "with its input off, the speaker stays silent whatever comes in", fmt("peak %.1f dBFS", db(input_off.peak)));
        room.engine.setSourceInput(room.speaker, true);
        Render silent = renderSeconds(room.engine, 0.3);
        check(silent.peak < 1e-5, "with nothing coming in, the speaker is silent", fmt("peak %.1f dBFS", db(silent.peak)));
        Render live = renderSeconds(room.engine, 1.0, tone);
        check(live.finite && live.rms_l > 0.02, "input is heard from the speaker", fmt("%.1f dBFS RMS", db(live.rms_l)));
        check(std::fabs(db(live.rms_l) - db(live.rms_r)) < 2.0, "and placed in the room (straight ahead here)",
              fmt("L-R %+.1f dB", db(live.rms_l) - db(live.rms_r)));
        Room click;
        click.quietRoom(click.speaker);
        click.engine.setSourceInput(click.speaker, true);
        click.face(-1.5f, 4.2f, 0.0f);
        renderSeconds(click.engine, 0.3);
        Render hit = renderSeconds(click.engine, 0.05, [](int64_t n) { return n == 0 ? 1.0f : 0.0f; });
        check(firstSound(hit) >= 0 && firstSound(hit) < 64, "input passes through in the same block it arrives",
              fmt("first sample after %.2f ms", firstSound(hit) * 1000.0 / 48000.0));

        // Opening the device with an input, on the silent null backend.
        std::string err;
        DeviceConfig duplex;
        duplex.mode = DeviceMode::Null;
        duplex.input_enabled = true;
        const bool opened = room.engine.openDevice(duplex, &err);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        EngineStats s = room.engine.stats();
        check(opened && s.live_input && s.blocks > 0, "the device opens with an input", fmt("%.0f blocks rendered", double(s.blocks)));
        const bool closed = room.engine.setLiveInput(false, &err);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        s = room.engine.stats();
        check(closed && !s.live_input && s.device_running, "and switching the input off keeps playback running", s.backend);
        room.engine.stopDevice();
    }

    {
        std::printf("\nPlayback engine and I/O\n");
        // The same four bars at every size, dry and with the reverb. (Each room begins the sequence again, because
        // changing the buffer size moves the first beat.)
        bool all_ok = true;
        std::string detail;
        for (bool reverb : {false, true}) {
            double reference = 0;
            detail += reverb ? "; with reverb" : "dry";
            for (int block : {128, 32, 64, 256, 512, 1024}) {
                Room room;
                std::string err;
                room.engine.setReverb(reverb);
                if (!room.engine.configure(48000, block, &err)) { all_ok = false; detail += " " + err; continue; }
                room.engine.setSequencerRunning(false);
                room.engine.setSequencerRunning(true);
                Render r = renderSeconds(room.engine, 10.43);
                const double measured = level(r);
                if (block == 128) reference = measured;
                if (!r.finite || r.peak >= 1.0 || std::fabs(measured - reference) > 0.1) all_ok = false;
                detail += fmt(" %.0f:", block) + fmt("%.2f", measured);
            }
        }
        check(all_ok, "every buffer size from 32 to 1024 renders the same mix", "frames:dBFS, " + detail);

        // Binaural rendering comes out a quarter of a buffer late. The reverb and the click don't pass through it, so
        // they are held back to match: all three keep their places against each other at every buffer size, and the
        // delay is part of the latency the engine reports. Measured with a single sample of sound through the speaker
        // on a beat, and with the click on that beat.
        const int kBeat = 24960;  // the second beat at 120 BPM (the sequence starts 20 ms after it is told to)
        auto heard = [&](int block, bool binaural, bool reverb, bool click) {
            Room room;
            std::string err;
            room.engine.configure(48000, block, &err);
            room.engine.setBinaural(binaural);
            room.quietRoom(click ? -1 : room.speaker);
            room.engine.setSourceInput(room.speaker, true);
            room.engine.setReverb(reverb);
            room.face(-1.5f, 4.2f, 0.0f);  // facing the speaker
            if (click) {
                room.engine.setTempo(120.0);
                room.engine.setClick(true);
                room.engine.setSequencerRunning(true);
            }
            return renderSeconds(room.engine, 0.75, [&](int64_t n) { return n == kBeat && !click ? 0.25f : 0.0f; });
        };
        bool in_step = true, reported = true;
        int reverb_after = 0, click_after = 0;
        std::string late;
        for (int block : {128, 32, 64, 256, 512, 1024}) {
            int direct[2] = {};
            for (bool binaural : {false, true}) {
                const Render dry = heard(block, binaural, false, false), wet = heard(block, binaural, true, false);
                std::vector<float> ring(dry.l.size());
                for (size_t i = 0; i < ring.size(); ++i) ring[i] = wet.l[i] - dry.l[i];
                direct[binaural] = onsetAfter(dry.l, 0);
                const int reverb = onsetAfter(ring, 0) - direct[binaural];
                const int click = onsetAfter(heard(block, binaural, false, true).l, size_t(kBeat) - 4800) - direct[binaural];
                if (block == 128 && !binaural) { reverb_after = reverb; click_after = click; }
                if (direct[binaural] < kBeat || reverb != reverb_after || click != click_after) in_step = false;
            }
            AudioEngine engine(EngineConfig{48000, block});
            const EngineStats on = engine.stats();
            engine.setBinaural(false);
            const EngineStats off = engine.stats();
            const int measured = direct[1] - direct[0];
            if (measured != block / 4 || std::fabs(on.binaural_ms - 1000.0 * measured / 48000.0) > 1e-9 || off.binaural_ms != 0.0 ||
                std::fabs(on.output_latency_ms - off.output_latency_ms - on.binaural_ms) > 1e-9 || direct[0] != kBeat)
                reported = false;
            late += fmt(" %.0f:", block) + fmt("%.0f", measured);
        }
        check(in_step, "the reverb and the click keep their places against the direct sound at every buffer size, binaural or not",
              fmt("the reverb starts %.0f samples after the direct sound and the click %.0f", reverb_after, click_after));
        check(reported, "binaural rendering is a quarter of a buffer late, plain stereo not at all, and the engine reports it",
              "frames:samples late," + late);
        Room timed;
        std::string err;
        DeviceConfig silent;
        silent.mode = DeviceMode::Null;
        silent.buffer_size = 256;
        const bool opened = timed.engine.openDevice(silent, &err);
        const EngineStats with = timed.engine.stats();
        timed.engine.setBinaural(false);
        const EngineStats without = timed.engine.stats();
        timed.engine.stopDevice();
        check(opened && with.buffer_ms > 0 && std::fabs(with.binaural_ms - 1000.0 * (with.block_size / 4) / with.sample_rate) < 1e-9 &&
                  std::fabs(with.output_latency_ms - (with.buffer_ms + with.device_ms + with.binaural_ms)) < 1e-9 &&
                  std::fabs(without.output_latency_ms - (without.buffer_ms + without.device_ms)) < 1e-9,
              "the output latency counts it while binaural is on, and stops when it is switched off",
              fmt("%.2f ms with binaural (%.2f buffer + %.2f binaural), ", with.output_latency_ms, with.buffer_ms, with.binaural_ms) +
                  fmt("%.2f ms without", without.output_latency_ms));

        Room room;
        renderSeconds(room.engine, 2.0);
        const bool reconfigured = room.engine.configure(44100, 64, &err);
        Render after = renderSeconds(room.engine, 6.0);
        check(reconfigured && after.finite && after.rms_l > 0.02, "changing sample rate and buffer size mid-song keeps the music going",
              fmt("%.1f dBFS at 44.1 kHz / 64 frames", db(after.rms_l)));

        // A four-output device with the mix sent to outputs 3-4.
        Room routed;
        routed.engine.setOutputChannels(2, 3);
        std::vector<float> out(4 * 4800);
        double energy[4] = {};
        for (int pass = 0; pass < 20; ++pass) {
            routed.engine.renderDevice(nullptr, 0, out.data(), 4, 4800);
            for (int i = 0; i < 4800; ++i)
                for (int c = 0; c < 4; ++c) energy[c] += double(out[size_t(4 * i + c)]) * out[size_t(4 * i + c)];
        }
        check(energy[0] == 0 && energy[1] == 0 && energy[2] > 1 && energy[3] > 1, "the mix goes to the chosen pair of outputs",
              "outputs 1-2 silent, 3-4 carry the mix");

        // A two-input device: a tone on input 2 only. The speaker plays whichever input it is assigned.
        Room inputs;
        inputs.quietRoom(inputs.speaker);
        inputs.engine.setSourceInput(inputs.speaker, true);
        inputs.face(-1.5f, 4.2f, 0.0f);
        auto two_in = [&](int assigned) {
            inputs.engine.setSourceInputChannel(inputs.speaker, assigned);
            std::vector<float> in(2 * 128), stereo(2 * 128);
            double e = 0;
            for (int b = 0; b < 200; ++b) {
                for (int i = 0; i < 128; ++i) {
                    in[size_t(2 * i)] = 0.0f;
                    in[size_t(2 * i + 1)] = 0.25f * float(std::sin(6.2831853 * 440.0 * double(b * 128 + i) / 48000.0));
                }
                inputs.engine.render(in.data(), 2, stereo.data(), 128);
                if (b >= 100) for (float v : stereo) e += double(v) * v;
            }
            return e;
        };
        const double on_one = two_in(0), on_two = two_in(1), on_all = two_in(LiveInput::kAllInputs);
        check(on_one < 1e-6 && on_two > 1 && on_all > 1, "the speaker plays the input it is assigned",
              "input 1: silent, input 2: tone, all inputs: tone");

        const auto outputs = AudioEngine::outputDevices();
        bool has_default = false;
        for (const auto& d : outputs) has_default = has_default || d.is_default;
        check(!outputs.empty() && has_default, "the system's output devices are listed", fmt("%.0f found", double(outputs.size())));
        DeviceConfig missing;
        missing.output_device = "A device that is not plugged in";
        check(!routed.engine.openDevice(missing, &err) && !routed.engine.stats().device_running,
              "asking for a device that is not connected fails cleanly", err);
    }

    {
        std::printf("\nPlaying each instrument by hand (its own loop switched off)\n");
        struct Case { const char* name; int note; bool sustains; };
        Room ids;
        const std::pair<int, Case> cases[] = {{ids.drums, {"drums", 36, false}}, {ids.bass, {"bass", 40, true}},
                                              {ids.pad, {"pad", 60, true}},      {ids.bells, {"bells", 79, false}}};
        for (const auto& [id, c] : cases) {
            Room room;
            room.soloOnly(id);
            room.engine.setReverb(false);
            room.engine.setSourceLoop(id, false);
            Render quiet = renderSeconds(room.engine, 0.5);
            room.engine.noteOn(id, c.note, 0.8f);
            Render played = renderSeconds(room.engine, 1.0);
            const int first = firstSound(played);
            const double held = tailPeak(played, 4800);
            room.engine.noteOff(id, c.note);
            Render after = renderSeconds(room.engine, 2.5);
            const bool ok = quiet.peak < 1e-5 && first >= 0 && first < room.engine.blockSize() && played.peak > 3e-3 &&
                            played.peak < 0.9 && (c.sustains ? held > 1e-3 : true) && tailPeak(after, 4800) < 1e-3;
            check(ok, std::string("the ") + c.name + (c.sustains ? " sound at once, hold while the key is down, and let go" : " sound at once"),
                  fmt("silent before; first sample after %.2f ms, peak %.0f dBFS", first * 1000.0 / 48000.0, db(played.peak)) +
                      fmt(", after a second %.0f dBFS, released %.0f dBFS", db(held), db(tailPeak(after, 4800))));
        }

        // The drum machine: every piece makes a sound, and they are laid out like a General MIDI kit.
        std::string pieces;
        bool all_sound = true;
        double low[Drums::kPieces], high[Drums::kPieces];
        for (int piece = 0; piece < Drums::kPieces; ++piece) {
            Room room;
            room.soloOnly(room.drums);
            room.engine.setReverb(false);
            room.engine.setSourceLoop(room.drums, false);
            room.face(0.5f, -2.0f, 0.0f);  // 1.6 m in front of the drums
            renderSeconds(room.engine, 0.1);
            room.engine.noteOn(room.drums, Drums::noteFor(Drums::Piece(piece)), 0.9f);
            Render r = renderSeconds(room.engine, 1.5);
            bandEnergy(r.l, 48000.0f, low[piece], high[piece]);
            if (r.peak < 0.02 || r.peak > 0.9 || !r.finite) all_sound = false;
            pieces += std::string(piece ? ", " : "") + Drums::pieceName(Drums::Piece(piece)) + fmt(" %.0f", db(r.peak));
        }
        check(all_sound, "all eight drum pieces sound at a sensible level", "peak dBFS: " + pieces);
        check(low[Drums::Kick] > 10 * high[Drums::Kick] && high[Drums::HatClosed] > 10 * low[Drums::HatClosed] &&
                  low[Drums::TomLow] > high[Drums::TomLow] && high[Drums::Crash] > 10 * low[Drums::Crash],
              "kick and toms are low, hats and crash are high", "energy below 300 Hz against above 4 kHz");
        check(Drums::pieceFor(36) == Drums::Kick && Drums::pieceFor(38) == Drums::Snare && Drums::pieceFor(42) == Drums::HatClosed &&
                  Drums::pieceFor(46) == Drums::HatOpen && Drums::pieceFor(49) == Drums::Crash && Drums::pieceFor(60) == Drums::Kick,
              "notes follow the General MIDI drum map, repeated in every octave", "36 kick, 38 snare, 42 and 46 hats, 49 crash");
    }

    {
        std::printf("\nThe sequencer\n");
        // Each instrument's part of the default groove, against levels measured before patterns became editable
        // (and so at the levels the engine had then).
        const double reference[4] = {-34.57, -33.60, -26.03, -24.89};
        const char* names[4] = {"drums", "bass", "pad", "bells"};
        std::string levels;
        bool same = true;
        for (int which = 0; which < 4; ++which) {
            Room room;
            oldLevels(room.engine);
            const int ids[4] = {room.drums, room.bass, room.pad, room.bells};
            room.soloOnly(ids[which]);
            room.engine.setReverb(false);
            const double measured = level(renderSeconds(room.engine, 10.43));
            if (std::fabs(measured - reference[which]) > 0.1) same = false;
            levels += std::string(which ? ", " : "") + names[which] + fmt(" %.2f", measured);
        }
        check(same, "the default patterns play the original groove", "dBFS: " + levels);
        Room defaults;
        check(defaults.engine.pattern(defaults.drums).size() == 86 && defaults.engine.pattern(defaults.pad).size() == 16 &&
                  defaults.engine.pattern(defaults.keys).empty() && defaults.engine.patternSteps(defaults.drums) == 64,
              "the patterns can be read back", fmt("drums %.0f notes, bass %.0f, bells %.0f", double(defaults.engine.pattern(defaults.drums).size()),
                                                   double(defaults.engine.pattern(defaults.bass).size()),
                                                   double(defaults.engine.pattern(defaults.bells).size())));

        // A kick on every beat, to measure the clock.
        Room room;
        room.soloOnly(room.drums);
        room.engine.setReverb(false);
        room.engine.setSwing(0.0);
        room.engine.setTempo(120.0);
        const int kick = Drums::noteFor(Drums::Kick), hat = Drums::noteFor(Drums::HatClosed);
        room.engine.setPatternSteps(room.drums, 16);
        room.engine.setPattern(room.drums, {{0, kick, 1, 1.0f, 1.0f}, {4, kick, 1, 1.0f, 1.0f}, {8, kick, 1, 1.0f, 1.0f}, {12, kick, 1, 1.0f, 1.0f}});
        std::string detail;
        Render fast = renderSeconds(room.engine, 4.1);
        check(spaced(onsets(fast, 4000), 0, 24000, detail), "at 120 BPM the beats are exactly half a second apart", detail);
        room.engine.setTempo(60.0);
        Render slow = renderSeconds(room.engine, 6.0);
        check(spaced(onsets(slow, 4000), 1, 48000, detail), "changing the tempo while it plays takes effect on the next step", detail);

        // Two hats a sixteenth apart: straight, then swung.
        room.engine.setTempo(120.0);
        room.engine.setPattern(room.drums, {{0, hat, 1, 0.8f, 1.0f}, {1, hat, 1, 0.8f, 1.0f}});
        renderSeconds(room.engine, 2.2);
        auto pairGap = [&]() {
            const auto on = onsets(renderSeconds(room.engine, 4.0), 1200);
            int smallest = 1 << 30;
            for (size_t i = 1; i < on.size(); ++i) smallest = std::min(smallest, on[i] - on[i - 1]);
            return smallest;
        };
        const int straight = pairGap();
        room.engine.setSwing(0.5);
        renderSeconds(room.engine, 2.0);
        const int swung = pairGap();
        check(std::abs(straight - 6000) <= 48 && std::abs(swung - 9000) <= 48, "swing delays the off-beat sixteenths",
              fmt("straight: %.0f samples apart, swing 50 %%: %.0f", straight, swung));

        // One kick at the start of a one-bar pattern, then the same pattern stretched to two bars.
        room.engine.setSwing(0.0);
        room.engine.setPattern(room.drums, {{0, kick, 1, 1.0f, 1.0f}});
        renderSeconds(room.engine, 2.0);
        const bool one_bar = spaced(onsets(renderSeconds(room.engine, 8.5), 4000), 0, 96000, detail);
        room.engine.setPatternSteps(room.drums, 32);
        renderSeconds(room.engine, 4.0);
        std::string detail_two;
        const bool two_bars = spaced(onsets(renderSeconds(room.engine, 16.5), 4000), 0, 192000, detail_two);
        check(one_bar && two_bars, "a pattern repeats after its own length (one bar, then two)", detail + "; " + detail_two);

        const bool replaced = room.engine.setPatternNote(room.drums, {0, kick, 1, 0.4f, 1.0f});
        const size_t after_replace = room.engine.pattern(room.drums).size();
        room.engine.removePatternNote(room.drums, 0, kick);
        renderSeconds(room.engine, 1.0);
        Render emptied = renderSeconds(room.engine, 4.5);
        check(replaced && after_replace == 1 && room.engine.pattern(room.drums).empty() && emptied.peak < 1e-4,
              "writing a note twice replaces it, and removing it leaves silence", fmt("peak %.0f dBFS", db(emptied.peak)));
        bool fits = true;
        for (int i = 0; i < kMaxPatternNotes; ++i) fits = room.engine.setPatternNote(room.drums, {i % 64, 30 + i / 64, 1, 0.5f, 1.0f}) && fits;
        check(fits && !room.engine.setPatternNote(room.drums, {0, 90, 1, 0.5f, 1.0f}), "a full pattern refuses another note",
              fmt("%.0f notes", double(room.engine.pattern(room.drums).size())));

        // A note that only plays some of the time.
        Room maybe;
        maybe.soloOnly(maybe.drums);
        maybe.engine.setReverb(false);
        maybe.engine.setTempo(240.0);
        maybe.engine.setPatternSteps(maybe.drums, 16);
        maybe.engine.setPattern(maybe.drums, {{0, hat, 1, 0.8f, 0.25f}, {8, hat, 1, 0.8f, 0.25f}});
        const size_t played = onsets(renderSeconds(maybe.engine, 100.0), 1200).size();  // 200 chances
        check(played > 25 && played < 80, "a note with a one-in-four chance plays about a quarter of the time", fmt("%.0f of 200", double(played)));

        // The Keys follow a pattern too, holding each note for its length.
        Room keys;
        keys.soloOnly(keys.keys);
        keys.engine.setReverb(false);
        keys.engine.setTempo(120.0);
        keys.engine.setPattern(keys.keys, {{0, 60, 2.0f, 0.8f, 1.0f}});
        Render phrase = renderSeconds(keys.engine, 2.0);
        double during = 0;
        for (size_t i = 12000; i < 20000; ++i) during = std::max(during, double(std::fabs(phrase.l[i])));
        check(during > 3e-3 && tailPeak(phrase, 24000) < 1e-3, "a sequenced Keys note sounds for its length and then stops",
              fmt("%.0f dBFS during, %.0f dBFS a second later", db(during), db(tailPeak(phrase, 24000))));

        // Switching one instrument's loop off, and the whole sequence off and on.
        Room loops;
        loops.engine.setReverb(false);
        renderSeconds(loops.engine, 1.0);
        loops.engine.setSourceLoop(loops.pad, false);
        renderSeconds(loops.engine, 0.5);
        const double pad_off = loops.engine.sourceLevel(loops.pad);
        renderSeconds(loops.engine, 3.0);
        loops.engine.setSourceLoop(loops.pad, true);
        renderSeconds(loops.engine, 4.0);
        check(pad_off < 1e-5 && loops.engine.sourceLevel(loops.pad) > 1e-3, "an instrument's loop can be switched off and back on",
              fmt("off %.0f dBFS, on again %.0f dBFS", db(pad_off), db(loops.engine.sourceLevel(loops.pad))));
        loops.engine.setSequencerRunning(false);
        renderSeconds(loops.engine, 3.0);
        Render stopped = renderSeconds(loops.engine, 1.0);
        const TransportState halted = loops.engine.transport();
        loops.engine.setSequencerRunning(true);
        Render restarted = renderSeconds(loops.engine, 0.5);
        check(stopped.peak < 1e-4 && !halted.running && halted.step == -1 && firstSound(restarted) >= 0 && firstSound(restarted) < 2400 &&
                  loops.engine.transport().step >= 0,
              "stopping the sequence leaves silence, and starting it begins again from the first beat",
              fmt("stopped %.0f dBFS; first sound %.0f ms after starting", db(stopped.peak), firstSound(restarted) * 1000.0 / 48000.0));
    }

    {
        std::printf("\nThe metronome\n");
        Room room;
        for (int s : {room.drums, room.bass, room.pad, room.bells, room.keys, room.speaker}) room.engine.setSourceMuted(s, true);
        room.engine.setTempo(120.0);
        Render off = renderSeconds(room.engine, 1.0);
        room.engine.setClick(true);
        Render clicks = renderSeconds(room.engine, 4.0);
        const auto on = onsets(clicks, 2000);
        std::string detail;
        check(off.peak < 1e-5 && spaced(on, 0, 24000, detail), "the click sounds on every beat, and only when switched on", detail);
        double apart = 0;
        for (size_t i = 0; i < clicks.l.size(); ++i) apart = std::max(apart, double(std::fabs(clicks.l[i] - clicks.r[i])));
        check(apart < 1e-6 && clicks.peak > 0.07 && clicks.peak < 0.17, "it is heard directly, the same in both ears, clear above the mix",
              fmt("peak %.1f dBFS, ears differ by %.0f dBFS", db(clicks.peak), db(apart)));
        // Clicks land on steps 4, 8, 12, 16...: the first bar line reached in this render is a higher pitch.
        int high_pitch = 0, low_pitch = 0;
        for (int at : on) (crossings(clicks, at, 480) > 30 ? high_pitch : low_pitch)++;
        check(high_pitch >= 1 && low_pitch >= 3 * high_pitch - 3 && low_pitch > high_pitch, "the first beat of each bar is a higher pitch",
              fmt("%.0f high, %.0f low", high_pitch, low_pitch));
        room.engine.setClickVolume(0.5f);
        Render quieter = renderSeconds(room.engine, 2.0);
        check(std::fabs(db(clicks.peak) - db(quieter.peak) - 6.0) < 1.0, "the click has its own volume",
              fmt("half volume is %.1f dB quieter", db(clicks.peak) - db(quieter.peak)));
    }

    {
        std::printf("\nWalls\n");
        const float kCeiling = 4.0f;
        auto path = [&](const std::vector<Wall>& walls, Vec3 ear, Vec3 source, float width = 14.0f, float depth = 10.0f) {
            RoomGeometry geometry;
            geometry.setRoom(width, depth, kCeiling, walls);
            return geometry.directPath(ear, source);
        };
        const Vec3 ear{-4.5f, 1.65f, -2.0f}, source{0.5f, 0.9f, -2.2f};
        const Wall partition{-2.5f, -3.25f, -2.5f, -0.55f, 0.3f, 3.0f};  // the default room's wall
        const DirectPath one = path({partition}, ear, source);
        check(one.blocked && one.count == 3 && one.differences[0] > 0.3f && one.differences[0] < one.differences[1] &&
                  std::fabs(one.via.x + 2.5f) < 0.2f && std::fabs(one.via.z + 3.4f) < 0.05f,
              "a wall in the way: three routes (round each end and over the top), arriving from the nearer end",
              fmt("%.2f, %.2f and %.2f m longer than the straight line", one.differences[0], one.differences[1], one.differences[2]));
        const DirectPath none = path({}, ear, source);
        const DirectPath beside = path({partition}, {-4.5f, 1.65f, 1.0f}, {0.5f, 0.9f, 0.5f});
        check(!none.blocked && none.differences[0] < -50.0f && !beside.blocked && beside.differences[0] < 0.0f && beside.differences[0] > -2.0f,
              "no wall in the way: clear, and the model knows how narrowly a nearby wall is missed", fmt("clears its end by a %.2f m detour", -beside.differences[0]));

        // The same scene turned through 37 degrees gives the same answer: walls can stand at any angle.
        const float c = std::cos(0.6458f), sn = std::sin(0.6458f);
        auto turn = [&](float x, float z) { return std::pair<float, float>{x * c - z * sn, x * sn + z * c}; };
        const auto [ax, az] = turn(partition.ax, partition.az);
        const auto [bx, bz] = turn(partition.bx, partition.bz);
        const auto [ex, ez] = turn(ear.x, ear.z);
        const auto [sx, sz] = turn(source.x, source.z);
        const auto [vx, vz] = turn(one.via.x, one.via.z);
        const DirectPath turned = path({{ax, az, bx, bz, 0.3f, 3.0f}}, {ex, ear.y, ez}, {sx, source.y, sz}, 30.0f, 30.0f);
        check(turned.blocked && turned.count == 3 && std::fabs(turned.differences[0] - one.differences[0]) < 1e-3f &&
                  std::fabs(turned.differences[2] - one.differences[2]) < 1e-3f && std::fabs(turned.via.x - vx) < 1e-3f && std::fabs(turned.via.z - vz) < 1e-3f,
              "a wall at an angle behaves like a straight one", fmt("%.3f m against %.3f m", turned.differences[0], one.differences[0]));

        // A second wall behind the first makes the way round longer.
        const DirectPath two = path({partition, {-1.0f, -4.0f, -1.0f, 0.5f, 0.3f, 3.0f}}, ear, source);
        check(two.blocked && two.differences[0] > one.differences[0] + 0.2f, "a second wall behind the first lengthens the way round",
              fmt("%.2f m with one wall, %.2f m with two", one.differences[0], two.differences[0]));

        // Two walls meeting in a corner: nothing gets through the join.
        const Wall south{-3.0f, 0.0f, 1.0f, 0.0f, 0.3f, kCeiling}, east{1.0f, 0.0f, 1.0f, -3.0f, 0.3f, kCeiling};
        const Vec3 inside{0.2f, 1.0f, -0.8f}, outside{2.0f, 1.65f, 1.5f};
        const DirectPath corner = path({south, east}, outside, inside);
        const DirectPath just_south = path({south}, outside, inside);
        check(corner.blocked && corner.count >= 1 && corner.differences[0] > just_south.differences[0] + 1.0f &&
                  !(std::fabs(corner.via.x - 1.0f) < 0.4f && std::fabs(corner.via.z) < 0.4f),
              "where two walls meet, sound has to go round the far ends, not through the join",
              fmt("%.2f m longer than the straight line, against %.2f m if the second wall weren't there", corner.differences[0], just_south.differences[0]));

        // A booth: four walls round the source.
        auto booth = [&](float height) {
            return std::vector<Wall>{{-1.0f, -1.0f, 1.0f, -1.0f, 0.3f, height}, {1.0f, -1.0f, 1.0f, 1.0f, 0.3f, height},
                                     {1.0f, 1.0f, -1.0f, 1.0f, 0.3f, height}, {-1.0f, 1.0f, -1.0f, -1.0f, 0.3f, height}};
        };
        const Vec3 in_booth{0.0f, 1.0f, 0.0f}, listener{4.0f, 1.65f, 0.5f};
        const DirectPath sealed = path(booth(kCeiling), listener, in_booth);
        const DirectPath open_top = path(booth(2.5f), listener, in_booth);
        check(sealed.blocked && sealed.count == 1 && sealed.differences[0] >= 10.0f, "a booth with walls to the ceiling seals its instrument in",
              "only what leaks through the wall is heard");
        check(open_top.blocked && open_top.count == 1 && open_top.differences[0] < 3.0f && std::fabs(open_top.via.y - 2.5f) < 1e-3f,
              "lower the booth's walls and the sound comes over the top", fmt("%.2f m longer, arriving from %.1f m up", open_top.differences[0], open_top.via.y));

        // A wall that runs into the room's own wall can't be passed at that end.
        const Wall to_edge{-7.0f, 0.0f, 0.0f, 0.0f, 0.3f, kCeiling};
        const DirectPath edge = path({to_edge}, {-3.0f, 1.65f, 2.0f}, {-3.0f, 1.0f, -2.0f});
        const DirectPath free_standing = path({{-6.0f, 0.0f, 0.0f, 0.0f, 0.3f, kCeiling}}, {-3.0f, 1.65f, 2.0f}, {-3.0f, 1.0f, -2.0f});
        check(edge.blocked && edge.count == 1 && edge.via.x > -0.5f && free_standing.count == 2,
              "a wall built out from the side of the room can only be passed at its free end", fmt("one route, round the end at x = %.2f", edge.via.x));

        // A low wall: you hear over it when you can see over it.
        const Wall low{0.0f, -2.0f, 0.0f, 2.0f, 0.3f, 1.2f};
        const DirectPath seen = path({low}, {-2.0f, 1.65f, 0.0f}, {2.0f, 1.6f, 0.0f});
        const DirectPath hidden = path({low}, {-2.0f, 1.65f, 0.0f}, {0.6f, 0.3f, 0.0f});
        check(!seen.blocked && seen.differences[0] < 0.0f && hidden.blocked && hidden.differences[0] < 0.6f && std::fabs(hidden.via.y - 1.2f) < 1e-3f,
              "a low wall hides only what is tucked behind it", fmt("seen over the top with %.2f m to spare; tucked behind, %.2f m longer",
                                                                    -seen.differences[0], hidden.differences[0]));

        // In the engine: the same booth, heard.
        Room room;
        room.soloOnly(room.drums);
        room.engine.setReverb(false);
        room.face(0.5f, -1.0f, 0.0f);
        renderSeconds(room.engine, 0.5);
        const double before = level(renderSeconds(room.engine, 10.43));
        std::vector<Wall> walls;
        for (Wall w : booth(kCeiling)) {  // moved over the drums
            w.ax += 0.5f; w.bx += 0.5f; w.az -= 3.6f; w.bz -= 3.6f;
            walls.push_back(w);
        }
        room.engine.setRoom(14.0f, 4.0f, 10.0f, walls);
        const bool hidden_now = room.engine.sourceBlocked(room.drums) && !room.engine.sourceBlocked(room.keys);
        renderSeconds(room.engine, 0.5);
        const double boxed = level(renderSeconds(room.engine, 10.43));
        room.engine.setRoom(14.0f, 4.0f, 10.0f, {});
        renderSeconds(room.engine, 0.5);
        const double after = level(renderSeconds(room.engine, 10.43));
        check(hidden_now && before - boxed > 15.0 && std::fabs(after - before) < 0.1 && !room.engine.sourceBlocked(room.drums),
              "building a booth round the drums shuts them away, and taking it down brings them back",
              fmt("%.1f dBFS open, %.1f dBFS boxed in, %.1f dBFS open again", before, boxed, after));
        room.engine.setRoom(14.0f, 4.0f, 10.0f, walls);
        room.face(0.5f, -3.6f, 0.0f);  // step inside the booth
        renderSeconds(room.engine, 0.5);
        check(!room.engine.sourceBlocked(room.drums) && room.engine.sourceBlocked(room.keys), "walking into the booth, the drums are clear and the rest is shut out",
              "the routes follow the listener");
    }

    {
        std::printf("\nThe size of the room\n");
        // How long the room takes to die away by 60 dB, judged from the tail of one snare hit.
        auto decay = [](Room& room) {
            while (!room.engine.roomSettled()) renderSeconds(room.engine, 0.1);
            renderSeconds(room.engine, 6.0);
            room.engine.noteOn(room.drums, 38, 1.0f);
            const Render r = renderSeconds(room.engine, 1.2);
            auto window = [&](double from, double to) {
                double e = 0;
                for (size_t i = size_t(from * 48000); i < size_t(to * 48000); ++i) e += double(r.l[i]) * r.l[i] + double(r.r[i]) * r.r[i];
                return 10.0 * std::log10(e + 1e-30);
            };
            return 60.0 * 0.4 / (window(0.35, 0.55) - window(0.75, 0.95));
        };
        Room room;
        room.soloOnly(room.drums);
        room.engine.setSourceLoop(room.drums, false);
        room.engine.setRoom(14.0f, 4.0f, 10.0f, {});
        const bool unchanged = room.engine.roomSettled() && std::fabs(room.engine.roomDecaySeconds() - 1.1f) < 1e-6f;
        const double normal = decay(room);
        room.engine.setRoom(30.0f, 8.0f, 20.0f, {});
        const float hall_says = room.engine.roomDecaySeconds();
        const bool busy = !room.engine.roomSettled();
        const double hall = decay(room);
        room.engine.setRoom(5.0f, 2.6f, 4.0f, {});
        const float booth_says = room.engine.roomDecaySeconds();
        const double small = decay(room);
        check(unchanged, "the default room keeps the reverb it has always had", "1.1 s, nothing rebuilt");
        check(busy && hall > 1.6 * normal && small < 0.7 * normal && std::fabs(hall_says - 2.22f) < 0.02f && std::fabs(booth_says - 0.555f) < 0.01f,
              "a bigger room rings longer and a smaller one shorter", fmt("snare tail: %.2f s in a 30 x 20 m hall, %.2f s by default, %.2f s in a 5 x 4 m room",
                                                                         hall, normal, small) +
                                                                         fmt(" (the engine reckons %.2f and %.2f s)", hall_says, booth_says));

        // Changing the room while a pad is sounding. Two identical rooms play the same thing and one of them changes
        // size: the difference between them is the reverb changing over, which should swell smoothly, not jump.
        Room changing, same;
        for (Room* each : {&changing, &same}) {
            each->soloOnly(each->pad);
            renderSeconds(each->engine, 2.0);
        }
        changing.engine.setRoom(6.0f, 3.0f, 5.0f, {});
        changing.engine.setRoom(9.0f, 3.0f, 7.0f, {});    // a burst of changes, as when a slider is dragged:
        changing.engine.setRoom(25.0f, 7.0f, 18.0f, {});  // the reverb takes them one at a time and ends at the last
        const Render with = renderSeconds(changing.engine, 1.0), without = renderSeconds(same.engine, 1.0);
        double biggest = 0, steepest = 0;
        for (size_t i = 1; i < with.l.size(); ++i) {
            const double now = double(with.l[i]) - without.l[i], last = double(with.l[i - 1]) - without.l[i - 1];
            biggest = std::max(biggest, std::fabs(now));
            steepest = std::max(steepest, std::fabs(now - last));
        }
        const bool mid_change = !changing.engine.roomSettled();
        for (int frame = 0; frame < 40 && !changing.engine.roomSettled(); ++frame) {
            changing.face(0.0f, 3.6f, 0.01f * float(frame));  // the game moves the listener every frame
            renderSeconds(changing.engine, 0.1);
        }
        const bool settled = changing.engine.roomSettled();
        std::string err;
        const bool reconfigured = changing.engine.configure(44100, 256, &err);
        const Render later = renderSeconds(changing.engine, 2.0);
        check(biggest > 1e-3 && steepest < 0.4 * biggest && mid_change && settled && reconfigured && later.finite && changing.engine.roomSettled(),
              "the room can change while music plays, without a click", fmt("the changeover peaks at %.4f and never steps by more than %.4f", biggest, steepest));
    }

    {
        std::printf("\nThe loop pedal\n");
        constexpr int64_t kSr = 48000;
        // Feeds a looper `samples` of input in blocks of 128 and returns what it played back. Bar lines, if any, fall
        // every `bar` samples from `bar_from` on the running clock `t`.
        struct Rig {
            std::vector<float> a, b;
            Looper looper;
            int64_t t = 0, bar = 0, bar_from = -1;
            explicit Rig(int64_t capacity) : a(size_t(capacity)), b(size_t(capacity)) { looper.setMemory(a.data(), b.data(), capacity); }
            std::vector<float> run(int64_t samples, const std::function<float(int64_t)>& input) {
                std::vector<float> out(size_t(samples), 0.0f), in(128);
                for (int64_t done = 0; done < samples; done += 128) {
                    const int n = int(std::min<int64_t>(128, samples - done));
                    for (int i = 0; i < n; ++i) in[size_t(i)] = input ? input(t + i) : 0.0f;
                    int64_t next_bar = -1;
                    if (bar_from >= 0) next_bar = t <= bar_from ? bar_from - t : (bar - (t - bar_from) % bar) % bar;
                    looper.process(in.data(), out.data() + done, n, next_bar, bar);
                    t += n;
                }
                return out;
            }
        };
        auto tone = [](double hz) { return [hz](int64_t n) { return 0.2f * float(std::sin(6.2831853 * hz * double(n) / 48000.0)); }; };
        auto rms = [](const std::vector<float>& x, size_t from, size_t to) {
            double e = 0;
            for (size_t i = from; i < to; ++i) e += double(x[i]) * x[i];
            return std::sqrt(e / double(std::max<size_t>(to - from, 1)));
        };
        auto same = [](const std::vector<float>& x, size_t a, size_t b, size_t n) {
            double worst = 0;
            for (size_t i = 0; i < n; ++i) worst = std::max(worst, double(std::fabs(x[a + i] - x[b + i])));
            return worst;
        };

        Rig rig(kSr * 10);
        rig.looper.act(Looper::Press);
        const bool recording = rig.looper.state() == Looper::Recording;
        rig.run(kSr, tone(440));
        rig.looper.act(Looper::Press);
        const int64_t length = rig.looper.length();
        std::vector<float> played = rig.run(kSr * 3, {});
        check(recording && rig.looper.state() == Looper::Playing && length == kSr && rms(played, 0, kSr) > 0.1 &&
                  same(played, 0, size_t(kSr), size_t(kSr)) < 1e-7 && same(played, 0, size_t(2 * kSr), size_t(kSr)) < 1e-7,
              "a press records, the next closes the loop, and it plays round and round", fmt("a %.2f s loop", double(length) / kSr));
        const double one_layer = rms(played, 1000, size_t(kSr) - 1000);

        rig.looper.act(Looper::Press);  // overdub a second tone over one whole pass
        const bool dubbing = rig.looper.state() == Looper::Overdubbing;
        rig.run(kSr, tone(660));
        rig.looper.act(Looper::Press);
        std::vector<float> two = rig.run(kSr * 2, {});
        const double with_dub = rms(two, 1000, size_t(kSr) - 1000);
        check(dubbing && std::fabs(with_dub / one_layer - std::sqrt(2.0)) < 0.05 && rig.looper.canUndo() && same(two, 0, size_t(kSr), size_t(kSr)) < 1e-7,
              "overdubbing lays a second part on top", fmt("level %.3f with one layer, %.3f with two", one_layer, with_dub));
        rig.looper.act(Looper::Undo);
        std::vector<float> undone = rig.run(kSr, {});
        rig.looper.act(Looper::Redo);
        std::vector<float> redone = rig.run(kSr, {});
        check(std::fabs(rms(undone, 1000, size_t(kSr) - 1000) - one_layer) < 1e-4 && std::fabs(rms(redone, 1000, size_t(kSr) - 1000) - with_dub) < 1e-4 &&
                  rig.looper.canUndo() && !rig.looper.canRedo(),
              "Undo takes the overdub off, and Redo puts it back", "");

        // A short overdub, part of the way round: the rest of the loop is copied over in the background.
        rig.looper.act(Looper::Undo);
        rig.run(kSr / 4, {});
        rig.looper.act(Looper::Press);
        rig.run(kSr / 4, tone(880));
        rig.looper.act(Looper::Press);
        rig.run(kSr, {});
        const bool undoable = rig.looper.canUndo();
        rig.looper.act(Looper::Press);  // straight into another overdub
        std::vector<float> while_dubbing = rig.run(kSr / 2, {});
        rig.looper.act(Looper::Undo);   // thrown away while it is still going
        std::vector<float> after = rig.run(kSr, {});
        rig.looper.act(Looper::Undo);   // and then the short one
        std::vector<float> original = rig.run(kSr, {});
        check(undoable && rig.looper.state() == Looper::Playing && rms(while_dubbing, 0, size_t(kSr / 2)) > 0.1 &&
                  std::fabs(rms(original, 1000, size_t(kSr) - 1000) - one_layer) < 1e-4 && rms(after, 0, size_t(kSr)) > rms(original, 0, size_t(kSr)),
              "Undo during an overdub throws that one away; Undo again goes back one more layer", "");

        rig.looper.act(Looper::Stop);
        std::vector<float> stopped = rig.run(kSr, {});
        rig.looper.act(Looper::Play);
        std::vector<float> again = rig.run(kSr, {});
        check(rig.looper.state() == Looper::Playing && rms(stopped, 0, size_t(kSr)) == 0.0 && same(again, 0, size_t(0), 10) == 0.0 &&
                  std::fabs(rms(again, 1000, size_t(kSr) - 1000) - one_layer) < 1e-4,
              "Stop silences it, and Play starts it again from the top", "");
        rig.looper.act(Looper::Clear);
        std::vector<float> cleared = rig.run(kSr, tone(440));
        check(rig.looper.state() == Looper::Empty && rig.looper.length() == 0 && rms(cleared, 0, size_t(kSr)) == 0.0,
              "Clear empties it", "");

        // Sync: the bars are half a second long and the first falls 10000 samples in.
        Rig synced(kSr * 10);
        synced.bar = kSr / 2;
        synced.bar_from = 10000;
        synced.looper.setSync(true);
        synced.looper.act(Looper::Press);
        synced.run(2000, tone(440));
        const bool waiting = synced.looper.state() == Looper::Waiting;
        synced.run(8000 + 30000, [](int64_t n) { return n >= 10000 && n < 10400 ? 1.0f : 0.0f; });  // a burst right on the bar line
        synced.looper.act(Looper::Press);  // a bar and a quarter in: it should carry on to two whole bars
        synced.run(30000, {});
        check(waiting && synced.looper.state() == Looper::Playing && synced.looper.length() == 2 * synced.bar &&
                  synced.a[0] == 0.0f && synced.a[150] > 0.5f,
              "with Sync, recording waits for the bar line and the loop comes out a whole number of bars",
              fmt("%.2f bars, starting on the bar line", double(synced.looper.length()) / double(synced.bar)));

        Rig small(kSr);
        small.looper.setDubAfterRecord(true);
        small.looper.act(Looper::Press);
        small.run(kSr * 2, tone(440));
        check(small.looper.length() == kSr && small.looper.state() == Looper::Overdubbing,
              "a recording that fills the pedal closes by itself; set to, it goes straight into overdubbing", "");
    }

    {
        std::printf("\nGuitar and bass amps\n");
        const InstrumentKind kinds[4] = {InstrumentKind::GuitarCombo, InstrumentKind::GuitarStack, InstrumentKind::BassCombo, InstrumentKind::BassStack};
        const char* names[4] = {"guitar combo", "guitar stack", "bass combo", "bass stack"};
        auto through = [](InstrumentKind kind, std::vector<float> signal, float gain, float bass = 5, float treble = 5) {
            AmpModel amp;
            amp.init(kind, 48000.0f);
            amp.setControl(AmpControl::Gain, gain);
            amp.setControl(AmpControl::Bass, bass);
            amp.setControl(AmpControl::Treble, treble);
            for (size_t i = 0; i < signal.size(); i += 128) amp.process(signal.data() + i, int(std::min<size_t>(128, signal.size() - i)));
            signal.erase(signal.begin(), signal.begin() + 4800);  // let the filters settle
            return signal;
        };
        std::vector<float> sine(48000 * 2);
        for (size_t i = 0; i < sine.size(); ++i) sine[i] = 0.1f * float(std::sin(6.2831853 * 220.0 * double(i) / 48000.0));
        auto distortion = [&](const std::vector<float>& x) {  // harmonics 2 to 5 against the fundamental
            double harmonics = 0;
            for (int h = 2; h <= 5; ++h) harmonics += tonePower(x, 220.0 * h, 48000.0);
            return std::sqrt(harmonics / tonePower(x, 220.0, 48000.0));
        };
        const double clean = distortion(through(InstrumentKind::GuitarCombo, sine, 0.0f));
        const double crunch = distortion(through(InstrumentKind::GuitarCombo, sine, 6.0f));
        const double lead = distortion(through(InstrumentKind::GuitarStack, sine, 9.0f));
        check(clean < 0.05 && crunch > 3 * clean && lead > 0.3, "the gain knob takes it from clean to distorted",
              fmt("harmonics against the note: %.1f %% clean, %.0f %% crunch, %.0f %% on the stack at 9", 100 * clean, 100 * crunch, 100 * lead));

        Rng rng;
        std::vector<float> noise(48000 * 2);
        for (float& v : noise) v = 0.05f * rng.next();
        double low_band, high_band, low_cut, high_cut;
        bandEnergy(through(InstrumentKind::GuitarCombo, noise, 2.0f, 10.0f, 10.0f), 48000.0f, low_band, high_band);
        bandEnergy(through(InstrumentKind::GuitarCombo, noise, 2.0f, 0.0f, 0.0f), 48000.0f, low_cut, high_cut);
        check(10 * std::log10(low_band / low_cut) > 10.0 && 10 * std::log10(high_band / high_cut) > 12.0,
              "Bass and Treble turn the lows and highs up and down", fmt("lows %.0f dB apart, highs %.0f dB apart, ends of the knobs",
                                                                         10 * std::log10(low_band / low_cut), 10 * std::log10(high_band / high_cut)));

        // Through each amp, a plucked string at the level an instrument gives an interface: how loud, how bright, how deep.
        std::string levels;
        double loudest = -100, quietest = 0;
        bool no_fizz = true;
        std::string fizz;
        double deep[4];
        for (int k = 0; k < 4; ++k) {
            const bool bass_amp = k >= 2;
            std::vector<float> dry = pluckedString(bass_amp ? 55.0 : 110.0, 2.0, 0.1f);
            std::vector<float> wet = through(kinds[k], dry, 5.0f);
            const double level = db(std::sqrt(std::inner_product(wet.begin(), wet.end(), wet.begin(), 0.0) / double(wet.size())));
            loudest = std::max(loudest, level);
            quietest = std::min(quietest, level);
            std::vector<float> hot = through(kinds[k], dry, 10.0f);
            double total = 0, above;
            for (float v : hot) total += double(v) * v;
            Biquad hp[2];
            for (auto& f : hp) f.set(Biquad::Highpass, 48000.0f, 9000.0f, 0.707f);
            above = 0;
            for (float v : hot) {
                const float x = hp[1].process(hp[0].process(v));
                above += double(x) * x;
            }
            if (10 * std::log10(above / total) > -30.0) no_fizz = false;
            fizz += std::string(k ? ", " : "") + names[k] + fmt(" %.0f", 10 * std::log10(above / total));
            deep[k] = 10 * std::log10(tonePower(through(kinds[k], std::vector<float>(sine.size(), 0.0f), 5.0f), 50.0, 48000.0) + 1e-30);
            std::vector<float> low_sine(48000 * 2);
            for (size_t i = 0; i < low_sine.size(); ++i) low_sine[i] = 0.05f * float(std::sin(6.2831853 * 45.0 * double(i) / 48000.0));
            deep[k] = 10 * std::log10(tonePower(through(kinds[k], low_sine, 0.0f), 45.0, 48000.0) / tonePower(low_sine, 45.0, 48000.0));
            levels += std::string(k ? ", " : "") + names[k] + fmt(" %.1f", level);
        }
        check(loudest - quietest < 4.0 && quietest > -26.0 && loudest < -10.0, "at their default settings the four amps are about as loud as each other",
              "dBFS RMS: " + levels);
        check(no_fizz, "even flat out, the cabinets keep the fizz above 9 kHz at least 30 dB down", "dB: " + fizz);
        check(deep[2] > deep[0] + 12.0 && deep[3] > deep[1] + 10.0, "the bass amps go deeper than the guitar amps",
              fmt("45 Hz: guitar combo %.0f dB, bass combo %.0f dB", deep[0], deep[2]) + fmt(", guitar stack %.0f dB, bass stack %.0f dB", deep[1], deep[3]));

        // Any head with any cabinet, and either bypassed.
        auto voiced = [](std::vector<float> signal, AmpHead head, bool head_on, AmpCabinet cabinet, bool cabinet_on) {
            AmpModel amp;
            amp.init(InstrumentKind::GuitarCombo, 48000.0f);
            amp.setHead(head, head_on);
            amp.setCabinet(cabinet, cabinet_on);
            for (size_t i = 0; i < signal.size(); i += 128) amp.process(signal.data() + i, int(std::min<size_t>(128, signal.size() - i)));
            signal.erase(signal.begin(), signal.begin() + 4800);
            return signal;
        };
        auto rmsDb = [](const std::vector<float>& x) {
            return db(std::sqrt(std::inner_product(x.begin(), x.end(), x.begin(), 0.0) / double(x.size())));
        };
        const char* head_names[kAmpHeads] = {"clean", "crunch", "high gain", "bass round", "bass punch"};
        const AmpCabinet usual[kAmpHeads] = {AmpCabinet::OpenBack1x12, AmpCabinet::OpenBack1x12, AmpCabinet::Closed4x12,
                                             AmpCabinet::Bass1x15, AmpCabinet::Bass8x10};
        std::string head_levels;
        bool heads_even = true, all_sound = true;
        for (int h = 0; h < kAmpHeads; ++h) {
            const std::vector<float> string_in = pluckedString(h >= 3 ? 55.0 : 110.0, 2.0, 0.1f);
            const double level = rmsDb(voiced(string_in, AmpHead(h), true, usual[h], true));
            heads_even = heads_even && std::fabs(level + 18.0) < 2.0;
            head_levels += std::string(" ") + head_names[h] + fmt(" %.1f;", level);
            for (int c = 0; c < kAmpCabinets; ++c) {
                const double any = rmsDb(voiced(string_in, AmpHead(h), true, AmpCabinet(c), true));
                if (!(any > -32.0 && any < -8.0)) all_sound = false;
            }
        }
        check(heads_even && all_sound, "every head goes with every cabinet, the five heads about as loud as each other through their usual cabinets",
              "dBFS RMS:" + head_levels);
        const std::vector<float> clean_note = sine;  // 220 Hz at 0.1
        const std::vector<float> no_head = voiced(clean_note, AmpHead::HighGain, false, AmpCabinet::OpenBack1x12, true);
        std::vector<float> both_off = voiced(clean_note, AmpHead::HighGain, false, AmpCabinet::Closed4x12, false);
        std::vector<float> clean_tail(clean_note.begin() + 4800, clean_note.end());
        double low_n, high_n, low_flat, high_flat, low_cab, high_cab;
        bandEnergy(noise, 48000.0f, low_n, high_n);
        bandEnergy(voiced(noise, AmpHead::Crunch, false, AmpCabinet::Closed4x12, false), 48000.0f, low_flat, high_flat);
        bandEnergy(voiced(noise, AmpHead::Crunch, false, AmpCabinet::Closed4x12, true), 48000.0f, low_cab, high_cab);
        check(distortion(no_head) < 0.01 && std::fabs(rmsDb(no_head) - rmsDb(clean_tail)) < 3.0 && both_off == clean_tail &&
                  std::fabs(10 * std::log10(high_flat / high_n)) < 1.0 && 10 * std::log10(high_cab / high_n) < -10.0,
              "bypassed, the head leaves the guitar clean for the cabinet; bypassed too, the cabinet is flat, and the amp passes it untouched",
              fmt("highs through the bypassed cabinet %+.1f dB, through the 4x12 %.0f dB", 10 * std::log10(high_flat / high_n), 10 * std::log10(high_cab / high_n)));

        // In the engine: a guitar into a combo, looped, then the guitar stops and the loop carries on through the amp.
        Room room;
        room.soloOnly(-1);
        room.engine.setReverb(false);
        room.engine.setSequencerRunning(false);
        const int amp = room.engine.addSource(InstrumentKind::GuitarCombo, {0.0f, 0.3f, 2.0f}, 1.0f, 0.4f);
        room.engine.setSourceInput(amp, true);
        std::vector<float> guitar = pluckedString(110.0, 1.0, 0.1f);
        const bool none_yet = !room.engine.looperStatus(amp).present && !room.engine.looperAction(amp, Looper::Press);
        const int loop_at = room.engine.addPedal(amp, PedalKind::Looper);
        const bool only_one = room.engine.addPedal(amp, PedalKind::Looper) < 0;
        check(none_yet && loop_at == 0 && only_one && room.engine.looperStatus(amp).present && room.engine.looperStatus(amp).state == Looper::Empty,
              "an amp starts without a loop pedal; one can be put on its board, but only one", "");
        renderSeconds(room.engine, 0.2);
        room.engine.looperAction(amp, Looper::Press);
        Render live = renderSeconds(room.engine, 1.0, [&](int64_t n) { return guitar[size_t(n) % guitar.size()]; });
        room.engine.looperAction(amp, Looper::Press);
        room.engine.setSourceInput(amp, false);  // the guitar is put down
        renderSeconds(room.engine, 0.5);
        const LooperStatus looping = room.engine.looperStatus(amp);
        Render loop = renderSeconds(room.engine, 2.0);
        check(live.rms_l > 0.003 && looping.state == Looper::Playing && std::fabs(looping.length - 1.0) < 0.01 && loop.rms_l > 0.5 * live.rms_l,
              "a guitar recorded on an amp's loop pedal keeps playing through the amp after the guitar stops",
              fmt("live %.0f dBFS, the loop %.0f dBFS, %.2f s long", db(live.rms_l), db(loop.rms_l), looping.length));
        room.engine.setAmpControl(amp, AmpControl::Master, 0.0f);
        renderSeconds(room.engine, 0.3);
        Render hushed = renderSeconds(room.engine, 0.5);
        room.engine.setAmpControl(amp, AmpControl::Master, 5.0f);
        std::string err;
        room.engine.configure(48000, 512, &err);  // a new buffer size keeps the loop
        renderSeconds(room.engine, 0.3);
        const LooperStatus kept = room.engine.looperStatus(amp);
        room.engine.configure(44100, 512, &err);  // a new sample rate can't
        const LooperStatus gone = room.engine.looperStatus(amp);
        check(hushed.peak < 1e-4 && kept.state == Looper::Playing && gone.present && gone.state == Looper::Empty &&
                  !room.engine.looperAction(room.drums, Looper::Press),
              "the amp's knobs act on the loop too; a loop survives a new buffer size but not a new sample rate", "");
    }

    {
        std::printf("\nEffect pedals\n");
        constexpr float kRate = 48000.0f;
        // Through a pedal in blocks of 128, with some controls set: {control, value}.
        auto through = [&](Pedal& pedal, std::vector<float> x, double beat = 0.0) {
            for (size_t i = 0; i < x.size(); i += 128) pedal.process(x.data() + i, int(std::min<size_t>(128, x.size() - i)), PedalTiming{beat, -1, 0});
            return x;
        };
        auto make = [&](PedalKind kind, std::initializer_list<std::pair<int, float>> settings = {}) {
            auto pedal = Pedal::make(kind, kRate);
            for (auto [control, value] : settings) pedal->setControl(control, value);
            return pedal;
        };
        auto sine = [&](double hz, double seconds, float level) {
            std::vector<float> x(size_t(seconds * kRate));
            for (size_t i = 0; i < x.size(); ++i) x[i] = level * float(std::sin(6.2831853 * hz * double(i) / kRate));
            return x;
        };
        auto rmsOf = [](const std::vector<float>& x, size_t from, size_t to) {
            double e = 0;
            for (size_t i = from; i < to && i < x.size(); ++i) e += double(x[i]) * x[i];
            return std::sqrt(e / double(std::max<size_t>(1, std::min(to, x.size()) - from)));
        };
        // How much a steady tone's level wavers: the quietest and loudest 10 ms windows, after the first half second.
        auto waver = [&](const std::vector<float>& x) {
            double low = 1e9, high = 0;
            for (size_t at = size_t(kRate / 2); at + 480 <= x.size(); at += 480) {
                const double r = rmsOf(x, at, at + 480);
                low = std::min(low, r);
                high = std::max(high, r);
            }
            return low / high;
        };
        auto harmonics = [&](const std::vector<float>& x, double hz) {
            double h = 0;
            for (int k = 2; k <= 6; ++k) h += tonePower(x, hz * k, kRate);
            return std::sqrt(h / tonePower(x, hz, kRate));
        };

        // Switched off, a pedal leaves the signal exactly as it was.
        bool untouched = true;
        std::string which;
        const std::vector<float> guitar = pluckedString(110.0, 2.0, 0.1f);
        for (int k = 0; k < kPedalKinds; ++k) {
            const PedalKind kind = PedalKind(k);
            if (kind == PedalKind::Delay || kind == PedalKind::Reverb || kind == PedalKind::Looper || kind == PedalKind::Plugin) continue;
            auto pedal = make(kind);
            pedal->setOn(false);
            if (through(*pedal, guitar) != guitar) {
                untouched = false;
                which += fmt(" %.0f", k);
            }
        }
        check(untouched, "a pedal switched off passes the guitar through untouched", untouched ? "true bypass, every stock pedal" : "changed by" + which);

        // The tuner.
        std::string notes;
        bool in_tune = true;
        for (double hz : {30.87, 41.20, 82.41, 110.0, 196.0, 329.63, 440.0 * std::pow(2.0, 15.0 / 1200.0)}) {
            std::vector<float> tone(static_cast<size_t>(kRate * 0.5));
            for (size_t i = 0; i < tone.size(); ++i)  // a string's tone: a fundamental and fading harmonics
                for (int h = 1; h <= 6; ++h) tone[i] += 0.05f / float(h) * float(std::sin(6.2831853 * hz * h * double(i) / kRate + h));
            auto tuner = Pedal::make(PedalKind::Tuner, kRate);
            std::vector<float> heard = through(*tuner, tone);
            const TunerReading r = static_cast<TunerPedal*>(tuner.get())->read();
            const double expected = 1200.0 * std::log2(hz / 440.0);
            const double off = (r.note - 69) * 100.0 + r.cents - expected;
            if (!r.pitched || std::fabs(off) > 1.0 || rmsOf(heard, 0, heard.size()) > 1e-6) in_tune = false;
            notes += fmt(" %.2f Hz: %.0f", hz, r.note) + fmt(" %+.1f cents;", r.cents);
        }
        check(in_tune, "the tuner names the note to within a cent, from a five-string bass's low B up, and mutes while it listens", notes);
        auto open_tuner = make(PedalKind::Tuner, {{0, 0.0f}});
        std::vector<float> quiet(size_t(kRate * 0.3), 0.00001f);
        const bool passes = through(*open_tuner, guitar) == guitar;
        through(*open_tuner, quiet);
        check(passes && !static_cast<TunerPedal*>(open_tuner.get())->read().pitched, "with Mute off it lets the guitar through, and silence has no pitch", "");

        // Dynamics.
        auto gate = make(PedalKind::Gate);
        std::vector<float> hiss(size_t(kRate * 2));
        Rng noise;
        for (float& v : hiss) v = 0.0003f * noise.next();  // about -75 dBFS
        std::vector<float> note_then_hiss = guitar;
        note_then_hiss.resize(size_t(kRate * 0.5));
        note_then_hiss.insert(note_then_hiss.end(), hiss.begin(), hiss.end());
        std::vector<float> gated = through(*gate, note_then_hiss);
        const double kept = rmsOf(gated, 0, size_t(kRate * 0.4)) / rmsOf(note_then_hiss, 0, size_t(kRate * 0.4));
        const double hiss_left = rmsOf(gated, size_t(kRate * 1.5), gated.size());
        check(kept > 0.97 && hiss_left < 1e-6, "the noise gate lets a note through and shuts out the hiss after it",
              fmt("the note at %.2f of its level, the hiss %.0f dB down", kept, db(hiss_left) - db(rmsOf(hiss, 0, hiss.size()))));

        auto comp = make(PedalKind::Compressor);
        std::vector<float> loud_soft = sine(220.0, 0.6, 0.5f), soft = sine(220.0, 0.6, 0.03f);
        loud_soft.insert(loud_soft.end(), soft.begin(), soft.end());
        std::vector<float> squeezed = through(*comp, loud_soft);
        const size_t half = size_t(kRate * 0.6);
        const double before_db = db(rmsOf(loud_soft, half / 2, half)) - db(rmsOf(loud_soft, half + half / 2, 2 * half));
        const double after_db = db(rmsOf(squeezed, half / 2, half)) - db(rmsOf(squeezed, half + half / 2, 2 * half));
        check(before_db > 20.0 && after_db < 10.0, "the compressor evens out loud and soft playing",
              fmt("%.0f dB between them going in, %.0f dB coming out", before_db, after_db));

        // Drive.
        const std::vector<float> note = sine(220.0, 1.0, 0.1f);
        auto mild = make(PedalKind::Overdrive, {{0, 0.0f}}), hard = make(PedalKind::Overdrive, {{0, 10.0f}});
        const double od_low = harmonics(through(*mild, note, 0.0), 220.0), od_high = harmonics(through(*hard, note, 0.0), 220.0);
        auto fuzz = make(PedalKind::Fuzz);
        const double fz = harmonics(through(*fuzz, note), 220.0);
        check(od_high > od_low + 0.1 && od_high > 0.15 && fz > od_high, "Drive takes the overdrive from nearly clean to distortion; the fuzz is fuzzier still",
              fmt("harmonics against the note: overdrive %.0f %% to %.0f %%, fuzz %.0f %%", 100 * od_low, 100 * od_high, 100 * fz));
        std::string level_text;
        bool level_matched = true;
        for (PedalKind kind : {PedalKind::Overdrive, PedalKind::Fuzz, PedalKind::Compressor}) {
            auto pedal = make(kind);
            std::vector<float> out = through(*pedal, guitar);
            const double change = db(rmsOf(out, 4800, out.size())) - db(rmsOf(guitar, 4800, guitar.size()));
            if (std::fabs(change) > 4.0) level_matched = false;
            level_text += fmt(" %+.1f dB", change);
        }
        check(level_matched, "with Level at 5, the overdrive, fuzz and compressor play a guitar back at about the level it came in", level_text);

        // Filter and modulation.
        auto saw = [&](float level) {
            std::vector<float> x(static_cast<size_t>(kRate));
            SawOsc osc;
            osc.setFreq(110.0f, kRate);
            for (float& v : x) v = level * osc.next();
            return x;
        };
        auto brightness = [&](const std::vector<float>& x) {
            Biquad hp[2];
            for (auto& f : hp) f.set(Biquad::Highpass, kRate, 1000.0f, 0.707f);
            double high = 0, all = 0;
            for (size_t i = size_t(kRate / 4); i < x.size(); ++i) {
                const float h = hp[1].process(hp[0].process(x[i]));
                high += double(h) * h;
                all += double(x[i]) * x[i];
            }
            return high / all;
        };
        auto wah_soft = make(PedalKind::EnvelopeFilter), wah_hard = make(PedalKind::EnvelopeFilter);
        const double soft_bright = brightness(through(*wah_soft, saw(0.01f))), hard_bright = brightness(through(*wah_hard, saw(0.3f)));
        check(hard_bright > 4.0 * soft_bright, "the envelope filter opens up the harder it is played",
              fmt("share above 1 kHz: %.1f %% played softly, %.1f %% played hard", 100 * soft_bright, 100 * hard_bright));
        const std::vector<float> steady = sine(1000.0, 3.0, 0.1f);
        auto chorus = make(PedalKind::Chorus), dry_chorus = make(PedalKind::Chorus, {{2, 0.0f}});
        auto phaser = make(PedalKind::Phaser);
        auto tremolo = make(PedalKind::Tremolo, {{1, 10.0f}, {2, 0.0f}});
        const double ch = waver(through(*chorus, steady)), ph = waver(through(*phaser, sine(800.0, 3.0, 0.1f)));
        std::vector<float> trem = through(*tremolo, steady);
        const double tr = waver(trem);
        int dips = 0;  // the tremolo's rate: count the troughs in two seconds
        bool falling = false;
        double last = 1e9;
        for (size_t at = size_t(kRate); at + 240 <= size_t(kRate * 3); at += 240) {
            const double r = rmsOf(trem, at, at + 240);
            if (falling && r > last) ++dips;
            falling = r < last;
            last = r;
        }
        const double expected_rate = 1.0 * std::pow(12.0, 0.5);  // Rate at 5, between 1 and 12 Hz
        check(ch < 0.95 && through(*dry_chorus, steady) == steady && ph < 0.6 && tr < 0.05 && std::fabs(dips / 2.0 - expected_rate) < 0.6,
              "chorus, phaser and tremolo make a steady note waver; the tremolo at its rate, all the way down with Depth at 10",
              fmt("quietest against loudest: chorus %.2f, phaser %.2f, tremolo %.2f", ch, ph, tr) + fmt(" pulsing at %.1f Hz", dips / 2.0));

        // Time.
        auto impulseResponse = [&](Pedal& pedal, double seconds, double beat = 0.0, double switch_off_at = -1.0) {
            std::vector<float> x(size_t(seconds * kRate), 0.0f);
            x[0] = 1.0f;
            const size_t off = switch_off_at < 0 ? x.size() : size_t(switch_off_at * kRate);
            for (size_t i = 0; i < x.size(); i += 128) {
                if (i >= off) pedal.setOn(false);
                if (i == size_t(seconds * kRate / 2) && switch_off_at >= 0) x[i] = 1.0f;  // a second hit, once it is off
                pedal.process(x.data() + i, int(std::min<size_t>(128, x.size() - i)), PedalTiming{beat, -1, 0});
            }
            return x;
        };
        auto loudest = [](const std::vector<float>& x, size_t from, size_t to) {
            size_t at = from;
            for (size_t i = from; i < to && i < x.size(); ++i)
                if (std::fabs(x[i]) > std::fabs(x[at])) at = i;
            return at;
        };
        auto delay = make(PedalKind::Delay);
        std::vector<float> echoes = impulseResponse(*delay, 1.5);
        const double set_time = 0.04 * std::pow(1.5 / 0.04, 0.55);  // Time at 5.5
        const size_t first = loudest(echoes, 100, echoes.size()), second = loudest(echoes, first + 200, echoes.size());
        check(std::fabs(double(first) / kRate - set_time) < 0.002 && std::fabs(double(second) / kRate - 2 * set_time) < 0.003 &&
                  std::fabs(echoes[second]) < std::fabs(echoes[first]),
              "the delay echoes at its Time, each repeat quieter", fmt("echoes at %.0f and %.0f ms, set to %.0f ms", 1000.0 * first / kRate, 1000.0 * second / kRate, 1000.0 * set_time));
        auto synced = make(PedalKind::Delay, {{4, 1.0f}, {0, 5.0f / 7.0f * 10.0f}});  // Sync, a quarter note
        auto dotted = make(PedalKind::Delay, {{4, 1.0f}, {0, 3.0f / 7.0f * 10.0f}});  // a dotted eighth
        const double beat = 0.5 * kRate;  // 120 BPM
        const size_t quarter = loudest(impulseResponse(*synced, 1.0, beat), 100, size_t(kRate)), dotted_at = loudest(impulseResponse(*dotted, 1.0, beat), 100, size_t(kRate));
        check(std::fabs(double(quarter) / kRate - 0.5) < 0.002 && std::fabs(double(dotted_at) / kRate - 0.375) < 0.002,
              "with Sync on it keeps time with the room: a quarter note and a dotted eighth at 120 BPM",
              fmt("%.0f ms and %.0f ms", 1000.0 * quarter / kRate, 1000.0 * dotted_at / kRate));
        auto trailing = make(PedalKind::Delay);
        std::vector<float> trail = impulseResponse(*trailing, 1.2, 0.0, 0.1);  // switched off before the echo comes
        const size_t late = loudest(trail, 100, size_t(0.59 * kRate));
        check(std::fabs(double(late) / kRate - set_time) < 0.002 && rmsOf(trail, size_t(0.6 * kRate) + 100, trail.size()) < 0.25 * rmsOf(trail, 100, size_t(0.59 * kRate)),
              "switched off, its echoes ring on, but nothing new goes in", "");
        auto reverb = make(PedalKind::Reverb);
        std::vector<float> tail = impulseResponse(*reverb, 3.0);
        double early = 0, later = 0;
        for (size_t i = size_t(0.1 * kRate); i < size_t(0.3 * kRate); ++i) early += double(tail[i]) * tail[i];
        for (size_t i = size_t(0.6 * kRate); i < size_t(0.8 * kRate); ++i) later += double(tail[i]) * tail[i];
        const double rt60 = 0.5 / ((10 * std::log10(early / later)) / 60.0), set_decay = 0.3 * std::pow(8.0 / 0.3, 0.5);
        check(early > 0 && std::fabs(rt60 / set_decay - 1.0) < 0.35, "the reverb's tail dies away over its Decay",
              fmt("about %.1f s to fall 60 dB, set to %.1f s", rt60, set_decay));

        // Switching on and off is click-free.
        auto drive = make(PedalKind::Overdrive, {{0, 10.0f}});
        std::vector<float> low = sine(82.0, 2.0, 0.2f);
        double steady_step = 0, switching_step = 0;
        for (size_t i = 0, block = 0; i < low.size(); i += 128, ++block) {
            if (block % 40 == 20) drive->setOn(block % 80 != 20);
            float before = i ? low[i - 1] : 0.0f;
            drive->process(low.data() + i, 128, PedalTiming{});
            for (size_t j = i; j < i + 128; ++j) {
                const double step = std::fabs(low[j] - before);
                before = low[j];
                (block % 40 >= 20 && block % 40 < 25 ? switching_step : steady_step) = std::max(block % 40 >= 20 && block % 40 < 25 ? switching_step : steady_step, step);
            }
        }
        check(switching_step <= 1.2 * steady_step, "stamping a pedal on and off makes no click",
              fmt("biggest step from one sample to the next: %.3f while switching, %.3f otherwise", switching_step, steady_step));

        // On an amp, in the engine.
        Room room;
        room.soloOnly(-1);
        room.engine.setReverb(false);
        room.engine.setSequencerRunning(false);
        const int amp = room.engine.addSource(InstrumentKind::GuitarCombo, {0.0f, 0.3f, 2.0f}, 1.0f, 0.4f);
        room.engine.setSourceInput(amp, true);
        const int od = room.engine.addPedal(amp, PedalKind::Overdrive);
        const int tuner_at = room.engine.addPedal(amp, PedalKind::Tuner, 0);
        const int dl = room.engine.addPedal(amp, PedalKind::Delay);
        std::vector<PedalStatus> board = room.engine.pedals(amp);
        check(od == 0 && tuner_at == 0 && dl == 2 && board.size() == 3 && board[0].kind == PedalKind::Tuner && board[1].kind == PedalKind::Overdrive &&
                  board[2].kind == PedalKind::Delay && board[1].on && board[1].controls[0] == 5.0f && room.engine.addPedal(room.drums, PedalKind::Fuzz) < 0,
              "an amp's pedals go where they are put, switched on, and only amps have them", "");
        room.engine.setPedalOn(amp, 0, false);  // the tuner off for now
        room.engine.movePedal(amp, 2, 1);
        room.engine.setPedalControl(amp, 2, 0, 12.0f);
        board = room.engine.pedals(amp);
        check(board[1].kind == PedalKind::Delay && board[2].kind == PedalKind::Overdrive && board[2].controls[0] == 10.0f && !board[0].on,
              "they can be moved along the board, and their knobs stop at 10", "");
        for (int k = 3; k < kMaxPedals; ++k) room.engine.addPedal(amp, PedalKind::Chorus);
        const bool full = room.engine.addPedal(amp, PedalKind::Chorus) < 0;
        for (int k = kMaxPedals - 1; k >= 3; --k) room.engine.removePedal(amp, k);
        room.engine.removePedal(amp, 1);  // the delay
        check(full && room.engine.pedals(amp).size() == 2, "a board holds 8 pedals, and they can be taken off again", "");

        // Copying pedals (Option-drag, or duplicating the amp): the same kind, switch and knobs, on this board or another.
        const int amp2 = room.engine.addSource(InstrumentKind::GuitarCombo, {2.0f, 0.3f, 2.0f}, 1.0f, 0.4f);
        std::string copy_error;
        const int copied_drive = room.engine.copyPedal(amp, 1, amp2, -1, &copy_error);
        const int copied_tuner = room.engine.copyPedal(amp, 0, amp2, 0, &copy_error);
        const int same_board = room.engine.copyPedal(amp, 1, amp, 0, &copy_error);
        const std::vector<PedalStatus> copies = room.engine.pedals(amp2);
        const bool onto_drums = room.engine.copyPedal(amp, 0, room.drums, -1, &copy_error) < 0;
        room.engine.addPedal(amp2, PedalKind::Looper);
        const bool second_looper = room.engine.copyPedal(amp2, 2, amp2, -1, &copy_error) < 0;
        check(copied_drive == 0 && copied_tuner == 0 && copies.size() == 2 && copies[0].kind == PedalKind::Tuner && !copies[0].on &&
                  copies[1].kind == PedalKind::Overdrive && copies[1].on && copies[1].controls[0] == 10.0f && same_board == 0 &&
                  room.engine.pedals(amp)[0].kind == PedalKind::Overdrive && room.engine.pedals(amp).size() == 3 && onto_drums && second_looper,
              "a pedal can be copied, switch and knobs and all, onto its own board or another amp's (but not a second loop pedal)", copy_error);
        room.engine.removePedal(amp, 0);
        room.engine.removeSource(amp2);

        std::vector<float> e_string(size_t(kRate * 2));
        for (size_t i = 0; i < e_string.size(); ++i)
            for (int h = 1; h <= 4; ++h) e_string[i] += 0.04f / float(h) * float(std::sin(6.2831853 * 82.41 * h * double(i) / kRate));
        int64_t played = 0;
        auto play = [&](double seconds) {
            Render r = renderSeconds(room.engine, seconds, [&](int64_t n) { return e_string[size_t(played + n) % e_string.size()]; });
            played += int64_t(r.l.size());
            return r;
        };
        play(0.5);
        Render loud = play(0.5);
        room.engine.setPedalOn(amp, 0, true);
        play(0.3);
        Render tuning = play(0.5);
        const TunerReading reading = room.engine.tuner(amp);
        room.engine.setPedalOn(amp, 0, false);
        play(0.3);
        Render back = play(0.5);
        check(reading.listening && reading.pitched && reading.note == 40 && std::fabs(reading.cents) < 3.0 && tuning.peak < 1e-5 && back.rms_l > 0.5 * loud.rms_l,
              "on the board, the tuner hushes the amp and reads the open E string; switched off, the amp sounds again",
              fmt("note %.0f, %+.1f cents", reading.note, reading.cents));

        // A loop pedal after a tremolo records what comes out of it.
        const int tremolo_at = room.engine.addPedal(amp, PedalKind::Tremolo);
        room.engine.setPedalControl(amp, tremolo_at, 1, 10.0f);
        room.engine.setPedalControl(amp, tremolo_at, 2, 10.0f);
        room.engine.addPedal(amp, PedalKind::Looper);
        room.engine.looperAction(amp, Looper::Press);
        play(1.0);
        room.engine.looperAction(amp, Looper::Press);
        room.engine.removePedal(amp, tremolo_at);
        room.engine.setSourceInput(amp, false);
        renderSeconds(room.engine, 0.3);
        Render looped = renderSeconds(room.engine, 2.0);
        double low_w = 1e9, high_w = 0;
        for (size_t at = 0; at + 480 <= looped.l.size(); at += 480) {
            const double r = rmsOf(looped.l, at, at + 480);
            low_w = std::min(low_w, r);
            high_w = std::max(high_w, r);
        }
        check(high_w > 0.001 && low_w / high_w < 0.2, "a loop pedal after a tremolo records what comes out of it: the loop keeps its tremolo after the tremolo is gone",
              fmt("quietest against loudest: %.2f", low_w / high_w));
        room.engine.removePedal(amp, int(room.engine.pedals(amp).size()) - 1);
        renderSeconds(room.engine, 0.3);
        Render unlooped = renderSeconds(room.engine, 0.5);
        check(!room.engine.looperStatus(amp).present && unlooped.peak < 1e-5, "taking the loop pedal off the board takes its loop with it", "");

        // A new sample rate: the pedals are made ready for it, and a delay still echoes after the same time.
        const int echo = room.engine.addPedal(amp, PedalKind::Delay);
        room.engine.setPedalOn(amp, 0, false);
        std::string err;
        room.engine.configure(44100, 256, &err);
        room.engine.setSourceInput(amp, true);
        bool hit = true;
        Render ping = renderSeconds(room.engine, 1.0, [&](int64_t n) {
            const bool now = hit && n == 0;
            hit = false;
            return now ? 0.5f : 0.0f;
        });
        size_t direct = 0, repeat = 0;
        for (size_t i = 0; i < ping.l.size(); ++i)
            if (std::fabs(ping.l[i]) > std::fabs(ping.l[direct])) direct = i;
        for (size_t i = direct + 2205; i < ping.l.size(); ++i)
            if (std::fabs(ping.l[i]) > std::fabs(ping.l[repeat])) repeat = i;
        check(echo == 2 && std::fabs(double(repeat - direct) / 44100.0 - set_time) < 0.01, "after a change of sample rate, the delay echoes after the same time",
              fmt("%.0f ms at 44.1 kHz", 1000.0 * double(repeat - direct) / 44100.0));
        room.engine.configure(48000, 128, &err);

        // Plug-ins: Apple's own AUDelay, which every Mac has.
        const std::vector<PluginDescription> plugins = AudioEngine::effectPlugins();
#ifdef __APPLE__
        const std::string au_delay = "AU:61756678:64656c79:6170706c";  // aufx dely appl
        bool listed = false;
        for (const auto& p : plugins)
            if (p.id == au_delay && p.name == "AUDelay" && p.maker == "Apple") listed = true;
        check(listed, "the effect plug-ins installed on this Mac are listed, Apple's AUDelay among them", fmt("%.0f effect plug-ins", double(plugins.size())));
        std::string why;
        std::unique_ptr<PluginInstance> au = PluginInstance::load(au_delay, &why);
        const bool prepared = au && au->prepare(48000.0, 4096, &why);
        std::vector<float> click(size_t(kRate * 1.3), 0.0f);
        click[0] = 1.0f;
        if (prepared)
            for (size_t i = 0; i < click.size(); i += 128) au->process(click.data() + i, int(std::min<size_t>(128, click.size() - i)));
        const size_t au_echo = loudest(click, 2000, click.size());
        check(prepared && std::fabs(double(au_echo) / kRate - 1.0) < 0.01 && std::fabs(click[au_echo]) > 0.05,
              "a plug-in loads and plays: AUDelay echoes a click a second later, as it is set to", prepared ? fmt("echo at %.3f s", double(au_echo) / kRate) : why);
        const int slot = room.engine.addPedal(amp, PedalKind::Plugin, 0);
        std::string load_error, wrong_error;
        const bool loaded = room.engine.loadPedalPlugin(amp, slot, au_delay, &load_error);
        const bool wrong = room.engine.loadPedalPlugin(amp, slot, "AU:00000000:00000000:00000000", &wrong_error);
        const bool not_a_plugin_pedal = room.engine.loadPedalPlugin(amp, 1, au_delay, &wrong_error);
        board = room.engine.pedals(amp);
        Render with_plugin = renderSeconds(room.engine, 0.5, [&](int64_t n) { return e_string[size_t(n) % e_string.size()]; });
        check(loaded && !wrong && !not_a_plugin_pedal && board[0].kind == PedalKind::Plugin && board[0].plugin.name == "AUDelay" && with_plugin.finite &&
                  with_plugin.rms_l > 0.001,
              "the Plug-in pedal on an amp holds AUDelay, and the amp plays through it", load_error.empty() ? "loaded" : load_error);
        const int amp3 = room.engine.addSource(InstrumentKind::GuitarCombo, {2.0f, 0.3f, 2.0f}, 1.0f, 0.4f);
        const int plugin_copy = room.engine.copyPedal(amp, slot, amp3, -1, &load_error);
        const std::vector<PedalStatus> amp3_board = room.engine.pedals(amp3);
        check(plugin_copy == 0 && amp3_board.size() == 1 && amp3_board[0].plugin.name == "AUDelay" && amp3_board[0].plugin.id == au_delay,
              "copying a Plug-in pedal loads a second of its plug-in onto the other amp, with its settings", load_error);
        room.engine.removeSource(amp3);
        room.engine.removePedal(amp, slot);
        renderSeconds(room.engine, 0.1);

        // Inserts on a channel: AUDelay on the drums, which then echo a second after each hit.
        Room mix;
        mix.quietRoom(mix.drums);
        mix.face(0.5f, -2.0f, 0.0f);
        std::string insert_error, bad_error;
        const bool inserted = mix.engine.setInsert(mix.drums, 1, au_delay, &insert_error);
        const bool bad = mix.engine.setInsert(mix.drums, 2, "AU:00000000:00000000:00000000", &bad_error) ||
                         mix.engine.setInsert(mix.drums, AudioEngine::kMaxInserts, au_delay, &bad_error);
        const std::vector<PedalStatus> slots = mix.engine.inserts(mix.drums);
        auto hitAndListen = [&]() {
            renderSeconds(mix.engine, 0.3);
            mix.engine.noteOn(mix.drums, 36, 1.0f);
            Render r = renderSeconds(mix.engine, 1.4);
            double hit = 0, between = 0, echo = 0;
            for (size_t i = 0; i < r.l.size(); ++i) {
                const double t = double(i) / kRate, a = std::fabs(r.l[i]);
                if (t < 0.3) hit = std::max(hit, a);
                else if (t > 0.5 && t < 0.9) between = std::max(between, a);
                else if (t > 0.95 && t < 1.3) echo = std::max(echo, a);
            }
            return std::make_tuple(hit, between, echo);
        };
        const auto [kick, between, echo_level] = hitAndListen();
        check(inserted && !bad && slots.size() == size_t(AudioEngine::kMaxInserts) && slots[1].plugin.name == "AUDelay" && slots[0].plugin.id.empty() &&
                  echo_level > 0.2 * kick && echo_level > 4.0 * between,
              "a plug-in on a channel's insert plays on that instrument: the drums echo a second after the kick",
              insert_error.empty() ? fmt("the kick at %.0f dBFS, its echo at %.0f dBFS", db(kick), db(echo_level)) : insert_error);
        mix.engine.setInsertOn(mix.drums, 1, false);
        const auto [hit2, between2, echo2] = hitAndListen();
        mix.engine.setInsertOn(mix.drums, 1, true);
        const bool cleared = mix.engine.clearInsert(mix.drums, 1) && !mix.engine.clearInsert(mix.drums, 1);
        const auto [hit3, between3, echo3] = hitAndListen();
        check(echo2 < 0.05 * hit2 && cleared && mix.engine.inserts(mix.drums)[1].plugin.id.empty() && echo3 < 0.05 * hit3 && hit3 > 0.5 * kick,
              "bypassed, or taken out, it no longer echoes", "");

        // Dragging inserts about: AUDelay moved from the drums to another channel, then copied back with its settings.
        mix.engine.setInsert(mix.drums, 1, au_delay, &insert_error);
        mix.engine.setInsert(mix.bass, 3, "AU:61756678:72766232:6170706c", &insert_error);  // AUReverb2, to be swapped out
        const bool moved = mix.engine.moveInsert(mix.drums, 1, mix.bass, 3);
        const auto drum_slots = mix.engine.inserts(mix.drums), bass_slots = mix.engine.inserts(mix.bass);
        const auto [hit4, between4, echo4] = hitAndListen();
        check(moved && bass_slots[3].plugin.name == "AUDelay" && drum_slots[1].plugin.name == "AUReverb2" && echo4 < 0.05 * hit4,
              "an insert dragged to a slot on another channel swaps places with what was there, and the drums stop echoing", "");
        const bool copied = mix.engine.copyInsert(mix.bass, 3, mix.drums, 1, &insert_error);
        const auto [hit5, between5, echo5] = hitAndListen();
        check(copied && mix.engine.inserts(mix.drums)[1].plugin.name == "AUDelay" && mix.engine.inserts(mix.bass)[3].plugin.name == "AUDelay" &&
                  echo5 > 0.2 * hit5,
              "copying it (Option-drag) leaves it where it was and puts a second one in the other slot", insert_error);
        std::string state_error;
        std::unique_ptr<PluginInstance> saved = PluginInstance::load(au_delay, &state_error), restored = PluginInstance::load(au_delay, &state_error);
        const bool both = saved && restored && saved->prepare(48000.0, 4096, &state_error) && restored->prepare(48000.0, 4096, &state_error);
        const std::vector<uint8_t> state = both ? saved->saveState() : std::vector<uint8_t>{};
        check(both && !state.empty() && restored->loadState(state) && restored->saveState().size() == state.size(),
              "a plug-in's settings can be saved and put back", fmt("%.0f bytes", double(state.size())));
#else
        check(plugins.empty(), "no plug-ins on this platform yet", "");
#endif
    }

    {
        std::printf("\nWhat kind of plug-in\n");
        const char* const kSeen[][3] = {
            {"UADx Lion 68 Super Lead Amp", "Universal Audio (UADx)", "Amps & cabinets"}, {"TONE3000", "TONE3000", "Amps & cabinets"},
            {"UADx Dream 65 Reverb Amp", "Universal Audio (UADx)", "Amps & cabinets"}, {"Pro-Q 3", "FabFilter", "EQ"},
            {"UADx 610-A Preamp and EQ", "Universal Audio (UADx)", "EQ"}, {"Pro-C 2", "FabFilter", "Dynamics"},
            {"UADx 1176LN Rev E Compressor", "Universal Audio (UADx)", "Dynamics"}, {"EchoBoy", "Soundtoys", "Delay"},
            {"UADx Galaxy Tape Echo", "Universal Audio (UADx)", "Delay"}, {"UADx Oxide Tape Recorder", "Universal Audio (UADx)", "Saturation & distortion"},
            {"UADx Ampex ATR-102 Master Tape", "Universal Audio (UADx)", "Saturation & distortion"}, {"ValhallaSupermassive", "Valhalla DSP, LLC", "Reverb"},
            {"RX 11 De-reverb", "iZotope", "Restoration"}, {"Little AlterBoy", "Soundtoys", "Pitch & vocal"}, {"PhaseMistress", "Soundtoys", "Modulation"},
            {"AULowpass", "Apple", "Filter"}, {"UADx SSL E Channel Strip", "Universal Audio (UADx)", "Channel strips"}, {"Gateway", "Atkinson Advanced Modeling, LLC", "Other"},
            {"Vocal EQ", "Antares", "EQ"}, {"Ozone 12", "iZotope", "Mastering"}, {"dearVR MIX", "Dear Reality", "Spatial"},
        };
        bool sorted = true;
        std::string wrong;
        for (const auto& seen : kSeen)
            if (guessPluginCategory(seen[0], seen[1], {}) != seen[2]) {
                sorted = false;
                wrong += std::string(" ") + seen[0] + " -> " + guessPluginCategory(seen[0], seen[1], {}) + ";";
            }
        check(sorted && guessPluginCategory("Mystery Box", "Someone", {"Effects", "Reverb"}) == "Reverb",
              "plug-ins are sorted by what they are, from their names (or their tags, where they have them)", sorted ? fmt("%.0f names", double(std::size(kSeen))) : wrong);
    }

    {
        std::printf("\nAdding and removing instruments\n");
        Room room;
        room.soloOnly(-1);  // the six that are already there keep quiet
        room.engine.setReverb(false);
        const int drums = room.engine.addSource(InstrumentKind::Drums, {1.0f, 0.9f, 2.0f}, 0.5f, 0.6f);
        Render untouched = renderSeconds(room.engine, 3.0);
        room.engine.noteOn(drums, 36, 0.9f);
        Render hit = renderSeconds(room.engine, 0.5);
        check(drums == 6 && room.engine.sourceCount() == 7 && room.engine.pattern(drums).empty() && untouched.peak < 1e-5 && hit.peak > 0.01,
              "a new instrument has an empty pattern: silent until it is played", fmt("id %.0f; untouched %.0f dBFS, played %.0f dBFS", drums, db(untouched.peak), db(hit.peak)));

        // Take a bass out of the room while it is holding a note.
        const int bass = room.engine.addSource(InstrumentKind::Bass, {0.0f, 1.0f, 2.0f}, 0.38f, 0.4f);
        room.engine.noteOn(bass, 40, 0.8f);
        Render sounding = renderSeconds(room.engine, 0.5);
        const bool removed = room.engine.removeSource(bass);
        const int count_after = room.engine.sourceCount();
        Render leaving = renderSeconds(room.engine, 0.3);
        auto steepest = [](const Render& r) {
            double step = 0;
            for (size_t i = 1; i < r.l.size(); ++i) step = std::max(step, double(std::fabs(r.l[i] - r.l[i - 1])));
            return step;
        };
        check(removed && count_after == 7 && sounding.peak > 0.01 && tailPeak(leaving, 4800) < 1e-5 && steepest(leaving) <= 1.5 * steepest(sounding),
              "removing an instrument fades it out without a click", fmt("gone to %.0f dBFS; steepest step %.4f while leaving, %.4f while playing",
                                                                      db(tailPeak(leaving, 4800)), steepest(leaving), steepest(sounding)));
        room.engine.noteOn(bass, 40, 0.8f);  // what is sent to an instrument that has gone is ignored
        room.engine.setSourceInput(bass, true);
        const bool refused = !room.engine.setPatternNote(bass, {0, 40, 1, 0.8f, 1.0f}) && !room.engine.removeSource(bass);
        Render ghost = renderSeconds(room.engine, 0.3);
        const int reused = room.engine.addSource(InstrumentKind::Pad, {0.0f, 1.6f, 2.0f}, 1.0f, 1.0f);
        check(refused && ghost.peak < 1e-5 && reused == bass && room.engine.pattern(reused).empty(),
              "its place in the room can be used again, and nothing reaches the one that left", fmt("the new pad took id %.0f", reused));

        int added = 0;
        while (room.engine.addSource(InstrumentKind::Bells, {0.0f, 1.6f, 0.0f}, 0.42f, 1.0f) >= 0) ++added;
        const int full = room.engine.sourceCount();
        room.engine.removeSource(drums);  // no waiting for it to fade: there is room for another straight away
        const int again = room.engine.addSource(InstrumentKind::Keys, {0.0f, 1.0f, 0.0f}, 0.2f, 0.9f);
        const bool refused_again = room.engine.addSource(InstrumentKind::Keys, {0.0f, 1.0f, 0.0f}, 0.2f, 0.9f) < 0;
        Render crowded = renderSeconds(room.engine, 1.0);
        check(full == AudioEngine::kMaxSources && again >= 0 && refused_again && crowded.finite,
              "the room holds 32 instruments and refuses a 33rd until one leaves", fmt("%.0f more fitted; full at %.0f", added, full));

        // A whole roomful swapped for another in one go, as loading a saved room will do.
        Room swap;
        int swapped = 0;
        for (int round = 0; round < 3; ++round) {
            std::vector<int> ids;
            int id;
            while ((id = swap.engine.addSource(InstrumentKind::Bells, {0.0f, 1.6f, 0.0f}, 0.42f, 1.0f)) >= 0) ids.push_back(id);
            if (swap.engine.sourceCount() == AudioEngine::kMaxSources) ++swapped;
            for (int each : ids) swap.engine.removeSource(each);
            for (int each : {swap.drums, swap.bass, swap.pad, swap.bells, swap.keys, swap.speaker}) swap.engine.removeSource(each);
            // ...and straight back in, before a single block has been rendered:
            swap.drums = swap.engine.addSource(InstrumentKind::Drums, {0.5f, 0.9f, -3.6f}, 0.50f, 0.6f);
            swap.bass = swap.engine.addSource(InstrumentKind::Bass, {-5.0f, 1.0f, -2.0f}, 0.38f, 0.4f);
            swap.pad = swap.engine.addSource(InstrumentKind::Pad, {4.8f, 1.6f, -1.6f}, 1.00f, 1.0f);
            swap.bells = swap.engine.addSource(InstrumentKind::Bells, {-4.6f, 1.6f, 2.4f}, 0.42f, 1.0f);
            swap.keys = swap.engine.addSource(InstrumentKind::Keys, {3.0f, 0.95f, 1.8f}, 0.20f, 0.9f);
            swap.speaker = swap.engine.addSource(InstrumentKind::Live, {-1.5f, 0.8f, 2.6f}, 1.0f, 0.7f);
            for (int each : {swap.drums, swap.bass, swap.pad, swap.bells, swap.keys}) swap.engine.loadDefaultPattern(each);
            renderSeconds(swap.engine, 0.5);
        }
        Render after_swaps = renderSeconds(swap.engine, 10.43);
        check(swapped == 3 && swap.speaker >= 0 && swap.engine.sourceCount() == 6 && after_swaps.finite && level(after_swaps) > -31.0 && level(after_swaps) < -24.0,
              "a full room can be emptied and refilled at once, three times over", fmt("the groove afterwards: %.1f dBFS", level(after_swaps)));
    }

    {
        std::printf("\nLevels\n");
        // A held pad note, heard from straight ahead at a chosen distance.
        auto heard = [](Room& room, float distance) {
            room.face(4.8f, -1.6f + distance, 0.0f);
            renderSeconds(room.engine, 0.3);
            return level(renderSeconds(room.engine, 0.5));
        };
        Room room;
        room.quietRoom(room.pad);
        room.engine.noteOn(room.pad, 57, 0.8f);
        renderSeconds(room.engine, 2.0);  // let the note swell
        const double at2 = heard(room, 2.0f), at4 = heard(room, 4.0f), at8 = heard(room, 8.0f);
        const double close = heard(room, 1.4f), closer = heard(room, 0.5f);
        check(std::fabs((at2 - at4) - 6.0) < 0.4 && std::fabs((at4 - at8) - 6.0) < 0.4, "each doubling of distance takes 6 dB off: the inverse square law",
              fmt("%.1f dB from 2 to 4 m, %.1f dB from 4 to 8 m", at2 - at4, at4 - at8));
        check(std::fabs(close - closer) < 0.3 && close > at2, "inside a metre and a half it gets no louder, however close",
              fmt("%.1f dBFS at 1.4 m, %.1f dBFS at 0.5 m", close, closer));
        room.engine.setDistanceFalloff(3.0f);
        renderSeconds(room.engine, 0.5);
        const double gentle2 = heard(room, 2.0f), gentle8 = heard(room, 8.0f);
        room.engine.setDistanceFalloff(0.0f);
        renderSeconds(room.engine, 0.5);
        const double flat2 = heard(room, 2.0f), flat8 = heard(room, 8.0f);
        room.engine.setDistanceFalloff(6.0f);
        check(std::fabs((gentle2 - gentle8) - 6.0) < 0.6 && std::fabs(flat2 - flat8) < 0.4, "the falloff can be set gentler: 3 dB a doubling, or none",
              fmt("2 to 8 m: %.1f dB at the 3 dB setting, %.1f dB at 0", gentle2 - gentle8, flat2 - flat8));
        const double before = heard(room, 2.0f);
        room.engine.setSourceGain(room.pad, 0.5f);  // the pad was added at 1.0
        const double halved = heard(room, 2.0f);
        room.engine.setSourceGain(room.pad, 2.0f);
        const double doubled = heard(room, 2.0f);
        check(std::fabs((before - halved) - 6.02) < 0.2 && std::fabs((doubled - before) - 6.02) < 0.2, "an instrument's own level can be turned down and up",
              fmt("half: %.1f dB, double: %+.1f dB", halved - before, doubled - before));

        // The output meter and the limiter, with the whole groove.
        Room mix;
        renderSeconds(mix.engine, 1.0);
        mix.engine.readMeter();
        Render normal = renderSeconds(mix.engine, 5.0);
        const MeterReading quiet = mix.engine.readMeter();
        const MeterReading again = mix.engine.readMeter();
        check(std::fabs(std::max(quiet.peak_l, quiet.peak_r) - float(normal.peak)) < 1e-6f && quiet.limiter_gain == 1.0f && quiet.clipped == 0 &&
                  quiet.rms_l > 0.02f && quiet.rms_l < 0.3f && again.peak_l == 0.0f,
              "the meter shows the output's peak and average, and starts afresh each time it is read",
              fmt("peak %.1f dBFS, average %.1f dBFS, limiter idle", db(normal.peak), db(quiet.rms_l)));
        mix.face(0.5f, -2.0f, 0.0f);  // a step away from the drums
        renderSeconds(mix.engine, 0.5);
        mix.engine.readMeter();
        Render beside = renderSeconds(mix.engine, 10.43);
        const MeterReading near_drums = mix.engine.readMeter();
        check(near_drums.limiter_gain == 1.0f && beside.peak < Limiter::kThreshold, "standing next to the drums leaves headroom: the limiter isn't touched",
              fmt("peak %.1f dBFS", db(beside.peak)));
        // Every instrument turned up 12 dB: far too loud for the mix.
        const std::pair<int, float> levels[] = {{mix.drums, 0.50f}, {mix.bass, 0.38f}, {mix.pad, 1.0f}, {mix.bells, 0.42f}, {mix.keys, 0.20f}};
        for (auto [id, gain] : levels) mix.engine.setSourceGain(id, gain * 4.0f);
        auto cycle = [&](MeterReading& m) {  // one time round the groove, as the meter sees it
            renderSeconds(mix.engine, 0.5);
            mix.engine.readMeter();
            Render r = renderSeconds(mix.engine, 10.43);
            m = mix.engine.readMeter();
            return r;
        };
        MeterReading limited, faded, boosted, clipped;
        Render pushed = cycle(limited);
        check(pushed.peak <= 1.0 && limited.limiter_gain < 0.8f && limited.clipped == 0 && pushed.finite, "pushed too hard, the limiter holds the output under full scale",
              fmt("peak %.1f dBFS with the limiter pulling down by up to %.1f dB", db(pushed.peak), -db(limited.limiter_gain)));
        mix.engine.setMasterVolume(0.5f);
        Render down = cycle(faded);
        check(std::fabs(db(faded.limiter_gain) - db(limited.limiter_gain)) < 1.0 && std::fabs((db(pushed.peak) - db(down.peak)) - 6.0) < 0.5,
              "the limiter comes before the master fader, as on a DAW's master track: turning the master down doesn't ease it",
              fmt("limiting by %.1f dB with the master at 0 dB, %.1f dB at -6 dB; the output %.1f dB quieter", -db(limited.limiter_gain),
                  -db(faded.limiter_gain), db(pushed.peak) - db(down.peak)));
        mix.engine.setMasterVolume(4.0f);
        Render up = cycle(boosted);
        check(up.peak == 1.0 && boosted.clipped > 0 && std::fabs(db(boosted.limiter_gain) - db(limited.limiter_gain)) < 1.0,
              "so the master fader pushed up past the limiter can clip the output, and the meter counts it",
              fmt("%.0f samples over", double(boosted.clipped)));
        mix.engine.setMasterVolume(1.0f);
        mix.engine.setLimiter(false);
        Render raw = cycle(clipped);
        check(raw.peak == 1.0 && clipped.clipped > 0 && clipped.limiter_gain == 1.0f, "with the limiter off the mix is left alone, and the meter counts what is cut off at full scale",
              fmt("%.0f samples over", double(clipped.clipped)));
    }

    {
        std::printf("\nToggles\n");
        Room room;
        renderSeconds(room.engine, 1.0);
        Render with_reverb = renderSeconds(room.engine, 5.2);
        room.engine.setReverb(false);
        renderSeconds(room.engine, 0.5);
        Render dry = renderSeconds(room.engine, 5.2);
        check(db(with_reverb.rms_l) - db(dry.rms_l) > 0.5, "reverb adds room sound",
              fmt("%.1f dB louder with reverb", db(with_reverb.rms_l) - db(dry.rms_l)));
        room.engine.setBinaural(false);
        Render plain = renderSeconds(room.engine, 2.0);
        check(plain.finite && plain.peak < 1.0, "plain stereo mode renders cleanly", fmt("peak %.1f dBFS", db(plain.peak)));

        // Binaural switched off and on while a low, pure note comes from the speaker (so that any jump shows), each
        // time at a different point in the wave. With a short buffer the change takes many blocks, with a long one two.
        bool smooth = true;
        std::string steps;
        for (int block : {128, 1024}) {
            Room held;
            std::string err;
            held.engine.configure(48000, block, &err);
            held.soloOnly(held.speaker);
            held.engine.setSequencerRunning(false);
            held.face(-0.5f, 4.2f, 0.4f);  // the speaker off to one side, where the two renderings differ most
            int64_t played = 0;
            auto note = [&](double seconds) {
                Render r = renderSeconds(held.engine, seconds, [&](int64_t n) { return 0.25f * float(std::sin(6.2831853 * 110.0 * double(played + n) / 48000.0)); });
                played += int64_t(r.l.size());
                return r;
            };
            note(1.0);
            const double steady = biggestStep(note(1.0));
            double switching = 0;
            for (int turn = 0; turn < 8; ++turn) {
                held.engine.setBinaural(turn % 2 == 1);
                switching = std::max(switching, biggestStep(note(0.2 + 0.013 * turn)));
            }
            if (switching > 1.5 * steady) smooth = false;
            steps += fmt(" %.0f frames: %.4f while switching, %.4f while playing;", block, switching, steady);
        }
        check(smooth, "switching binaural off and on makes no click", "biggest step from one sample to the next:" + steps);
        room.engine.setMasterVolume(0.5f);
        renderSeconds(room.engine, 0.5);
        Render half = renderSeconds(room.engine, 2.0);
        room.engine.setMasterVolume(1.0f);
        renderSeconds(room.engine, 0.5);
        Render full = renderSeconds(room.engine, 2.0);
        check(std::fabs((db(full.rms_l) - db(half.rms_l)) - 6.0) < 2.5, "the master volume scales the output",
              fmt("half volume is %.1f dB quieter", db(full.rms_l) - db(half.rms_l)));
    }

    std::printf("\n%s\n", failures ? "SOME CHECKS FAILED" : "All checks passed");
    return failures ? 1 : 0;
}
