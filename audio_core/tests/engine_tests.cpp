// Offline checks for the audio core: renders the prototype's room without a sound card and measures it.
// Run: build/engine_tests            (exit code 0 = all checks passed)
//      build/engine_tests --dump file  (writes what the default room plays, to compare before and after a change)
//      build/engine_tests --paths in out  (the wall model's answers for the listener and source positions in `in`)
//      build/engine_tests --device ["name" [buffer [left right]]]
//                                    (lists audio devices, opens one silently, prints its latency)
//      build/engine_tests --midi     (lists MIDI devices and reports the notes they send for 15 seconds)

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "acoustics.h"
#include "engine.h"
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

int firstSound(const Render& r) {
    for (size_t i = 0; i < r.l.size(); ++i)
        if (std::fabs(r.l[i]) > 1e-4f || std::fabs(r.r[i]) > 1e-4f) return int(i);
    return -1;
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
    std::printf("buffer %.2f ms + device %.2f ms = output latency %.2f ms; %llu blocks rendered\n", s.buffer_ms,
                s.device_ms, s.output_latency_ms, (unsigned long long)s.blocks);
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

// Writes what the default room plays to a file of raw 32-bit floats (interleaved stereo): two loops of the full
// mix, then one loop of each sequenced instrument alone with the reverb off. Comparing two dumps shows whether a
// change to the engine altered the sound.
int dumpGroove(const char* path) {
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
        write(renderSeconds(room.engine, 20.86));
    }
    for (int which = 0; which < 4; ++which) {
        Room room;
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
    if (argc > 2 && std::string(argv[1]) == "--dump") return dumpGroove(argv[2]);
    if (argc > 3 && std::string(argv[1]) == "--paths") return dumpPaths(argv[2], argv[3]);
    if (argc > 1 && std::string(argv[1]) == "--device") {  // --device ["name" [buffer [left right]]]
        DeviceConfig config;
        if (argc > 2) config.output_device = argv[2];
        if (argc > 3) config.buffer_size = std::atoi(argv[3]);
        if (argc > 5) { config.output_left = std::atoi(argv[4]) - 1; config.output_right = std::atoi(argv[5]) - 1; }
        return deviceProbe(config);
    }
    if (argc > 1 && std::string(argv[1]) == "--midi") return midiProbe(argc > 2 ? std::atoi(argv[2]) : 15);
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
        check(rms > 0.05 && rms < 0.3, "comfortable level", fmt("%.1f dBFS RMS (L %.1f, R %.1f)", db(rms), db(r.rms_l), db(r.rms_r)));
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
            check(nobody.peak < 1e-5, "with nobody at an instrument, the controller plays nothing", fmt("peak %.0f dBFS", db(nobody.peak)));

            room.engine.setMidiTarget(room.keys);  // the player sits down at the Keys
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

            // The controller plays whichever instrument the player is at.
            renderSeconds(room.engine, 1.0);
            room.engine.setSourceMuted(room.drums, false);
            room.engine.setSourceMuted(room.bass, false);
            room.engine.setMidiTarget(room.drums);
            keyboard.send(0x90, 36, 110);  // the kick on a General MIDI drum map
            renderSeconds(room.engine, 0.02);
            const double drums_level = room.engine.sourceLevel(room.drums), keys_level = room.engine.sourceLevel(room.keys);
            keyboard.send(0x80, 36, 0);
            check(drums_level > 1e-3 && keys_level < 1e-5, "at the drums, the controller plays the drums and not the Keys",
                  fmt("drums %.0f dBFS, keys %.0f dBFS", db(drums_level), db(keys_level)));
            room.engine.setMidiTarget(room.bass);
            keyboard.send(0x90, 40, 100);
            renderSeconds(room.engine, 0.5);
            const double held_bass = room.engine.sourceLevel(room.bass);
            room.engine.setMidiTarget(room.keys);  // walking away with the key still down
            renderSeconds(room.engine, 0.3);
            const double left_bass = room.engine.sourceLevel(room.bass);
            keyboard.send(0x80, 40, 0);
            check(held_bass > 1e-3 && left_bass < 1e-4, "a held bass note sustains, and moving to another instrument lets it go",
                  fmt("held %.0f dBFS, after leaving %.0f dBFS", db(held_bass), db(left_bass)));

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
        Render silent = renderSeconds(room.engine, 0.3);
        check(silent.peak < 1e-5, "with nothing coming in, the speaker is silent", fmt("peak %.1f dBFS", db(silent.peak)));
        auto tone = [](int64_t n) { return 0.25f * float(std::sin(6.2831853 * 440.0 * double(n) / 48000.0)); };
        Render live = renderSeconds(room.engine, 1.0, tone);
        check(live.finite && live.rms_l > 0.02, "input is heard from the speaker", fmt("%.1f dBFS RMS", db(live.rms_l)));
        check(std::fabs(db(live.rms_l) - db(live.rms_r)) < 2.0, "and placed in the room (straight ahead here)",
              fmt("L-R %+.1f dB", db(live.rms_l) - db(live.rms_r)));
        Room click;
        click.quietRoom(click.speaker);
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
        double reference = 0;
        bool all_ok = true;
        std::string detail;
        for (int block : {128, 32, 64, 256, 512, 1024}) {
            Room room;
            std::string err;
            if (!room.engine.configure(48000, block, &err)) { all_ok = false; detail += " " + err; continue; }
            Render r = renderSeconds(room.engine, 10.43);
            const double level = db(std::sqrt((r.rms_l * r.rms_l + r.rms_r * r.rms_r) / 2));
            if (block == 128) reference = level;
            if (!r.finite || r.peak >= 1.0 || std::fabs(level - reference) > 1.0) all_ok = false;
            detail += fmt(" %.0f:", block) + fmt("%.1f", level);
        }
        check(all_ok, "every buffer size from 32 to 1024 renders the same mix", "frames:dBFS" + detail);

        Room room;
        renderSeconds(room.engine, 2.0);
        std::string err;
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
        // Each instrument's part of the default groove, against levels measured before patterns became editable.
        const double reference[4] = {-34.57, -33.60, -26.03, -24.89};
        const char* names[4] = {"drums", "bass", "pad", "bells"};
        std::string levels;
        bool same = true;
        for (int which = 0; which < 4; ++which) {
            Room room;
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
        check(apart < 1e-6 && clicks.peak > 0.15 && clicks.peak < 0.35, "it is heard directly, the same in both ears, clear above the mix",
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
        room.engine.setMidiTarget(bass);
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
        check(swapped == 3 && swap.speaker >= 0 && swap.engine.sourceCount() == 6 && after_swaps.finite && level(after_swaps) > -24.0 && level(after_swaps) < -19.0,
              "a full room can be emptied and refilled at once, three times over", fmt("the groove afterwards: %.1f dBFS", level(after_swaps)));
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
