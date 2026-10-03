// Offline checks for the audio core: renders the prototype's room without a sound card and measures it.
// Run: build/engine_tests   (exit code 0 = all checks passed)

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "engine.h"

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

Render renderSeconds(AudioEngine& e, double seconds, const std::function<void(int64_t)>& per_block = {}) {
    const int block = e.blockSize();
    const int64_t frames = int64_t(seconds * e.sampleRate()) / block * block;
    std::vector<float> buf(size_t(block) * 2);
    Render out;
    double el = 0, er = 0;
    for (int64_t f = 0; f < frames; f += block) {
        if (per_block) per_block(f);
        e.render(buf.data(), block);
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

// The prototype's room: same instruments, positions, levels and reverb sends.
struct Room {
    AudioEngine engine;
    int drums, bass, pad, bells, keys;
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
        face(0.0f, 3.6f, 0.0f);
    }
    // yaw 0 faces -z (north); positive yaw turns left
    void face(float x, float z, float yaw) {
        engine.setListener({x, 1.65f, z}, {-std::sin(yaw), 0, -std::cos(yaw)}, {0, 1, 0});
    }
    void soloOnly(int id) {
        for (int s : {drums, bass, pad, bells, keys}) engine.setSourceMuted(s, s != id);
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

}  // namespace

// Opens the real output device with no sources (so it plays silence) and reports what the OS says about latency.
int deviceProbe() {
    EngineConfig config;
    config.sample_rate = AudioEngine::defaultOutputSampleRate();
    AudioEngine engine(config);
    std::string err;
    if (!engine.init(&err) || !engine.startDevice(DeviceMode::Hardware, &err)) {
        std::printf("device probe failed: %s\n", err.c_str());
        return 1;
    }
    std::this_thread::sleep_for(std::chrono::seconds(1));
    const EngineStats s = engine.stats();
    std::printf("backend %s, %d Hz, period %d frames\n", s.backend.c_str(), s.sample_rate, s.device_period);
    std::printf("buffer %.2f ms + device %.2f ms = output latency %.2f ms; %llu blocks rendered\n", s.buffer_ms,
                s.device_ms, s.output_latency_ms, (unsigned long long)s.blocks);
    return s.blocks > 0 ? 0 : 1;
}

int main(int argc, char** argv) {
    if (argc > 1 && std::string(argv[1]) == "--device") return deviceProbe();
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
        check(rms > 0.03 && rms < 0.3, "comfortable level", fmt("%.1f dBFS RMS (L %.1f, R %.1f)", db(rms), db(r.rms_l), db(r.rms_r)));
        check(secs < 10.43 / 4, "renders well faster than real time", fmt("%.1fx real time", 10.43 / secs));
        for (int id = 0; id < 5; ++id) std::printf("    source %d level %.3f\n", id, room.engine.sourceLevel(id));
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
        std::printf("\nOcclusion (drums alone, reverb off: kick for the lows, hats for the highs)\n");
        Room room;
        room.soloOnly(room.drums);
        room.engine.setReverb(false);
        room.face(0.0f, -1.0f, 0.0f);
        renderSeconds(room.engine, 0.5);
        Render clear = renderSeconds(room.engine, 10.43);
        room.engine.setSourceVisibility(room.drums, 0.0f);
        renderSeconds(room.engine, 0.5);
        Render blocked = renderSeconds(room.engine, 10.43);
        double cl, ch, bl, bh;
        bandEnergy(clear.l, 48000.0f, cl, ch);
        bandEnergy(blocked.l, 48000.0f, bl, bh);
        const double low_drop = 10 * std::log10(cl / bl), high_drop = 10 * std::log10(ch / bh);
        check(low_drop < 6.0, "behind the wall the lows mostly get through", fmt("lows down %.1f dB", low_drop));
        check(high_drop > 12.0, "and the highs are cut", fmt("highs down %.1f dB", high_drop));
    }

    {
        std::printf("\nKeys latency (keys alone, reverb off)\n");
        Room room;
        room.soloOnly(room.keys);
        room.engine.setReverb(false);
        room.engine.setSequencerRunning(false);
        room.face(3.0f, 3.0f, 0.0f);
        renderSeconds(room.engine, 0.3);
        // The note-on is queued just before a block; measure when sound first leaves the engine.
        const int block = room.engine.blockSize();
        room.engine.noteOn(room.keys, 60, 0.8f);
        Render r = renderSeconds(room.engine, 0.05);
        int first = -1;
        for (size_t i = 0; i < r.l.size(); ++i)
            if (std::fabs(r.l[i]) > 1e-4f || std::fabs(r.r[i]) > 1e-4f) { first = int(i); break; }
        check(first >= 0 && first < block, "a note sounds in the very next block",
              fmt("first sample after %.2f ms (block is %.2f ms)", first * 1000.0 / 48000.0, block * 1000.0 / 48000.0));
        room.engine.noteOff(room.keys, 60);
        Render tail = renderSeconds(room.engine, 1.0);
        double end_peak = 0;
        for (size_t i = tail.l.size() - 4800; i < tail.l.size(); ++i) end_peak = std::max(end_peak, double(std::fabs(tail.l[i])));
        check(end_peak < 1e-3, "note-off releases the note", fmt("last 100 ms peak %.1f dBFS", db(end_peak)));
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
    }

    std::printf("\n%s\n", failures ? "SOME CHECKS FAILED" : "All checks passed");
    return failures ? 1 : 0;
}
