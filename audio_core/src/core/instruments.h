#pragma once

// Synthesized instruments, ported from the browser prototype. Every voice is pre-allocated, so nothing here
// allocates on the audio thread. Each instrument can be played two ways: live (noteOn/noteOff, from the computer
// keyboard or a MIDI controller) and by the sequencer (play), where a note has a set length and can start partway
// into a block (`delay` samples), which is what makes the sequencer sample-accurate.

#include <array>
#include <cstdint>
#include <vector>

#include "dsp.h"

namespace sr {

// GarageDrums and StudioDrums are acoustic kits (AcousticKit); PluginSynth plays an instrument plug-in (plugin_synth.h).
enum class InstrumentKind : uint8_t {
    Drums, Bass, Pad, Bells, Keys, GarageDrums, StudioDrums, PluginSynth, Live, GuitarCombo, GuitarStack, BassCombo, BassStack,
    Bus,  // not an instrument: a routing folder's bus, an aux input that tracks play into (see AudioEngine::setSourceOutput)
    Mic,  // not an instrument: a microphone, hearing the room from where it stands (see AudioEngine::Source::Capsule)
    StereoMic  // two microphones as one stereo track (a stereo pair: XY, ORTF, a spaced pair, Blumlein, mid-side)
};
constexpr int kInstrumentKinds = 14;

// The kinds that play notes; that play an audio input (the Speaker and the amps); the amps.
inline bool playsNotes(InstrumentKind kind) { return kind <= InstrumentKind::PluginSynth; }
inline bool isLiveInput(InstrumentKind kind) { return kind >= InstrumentKind::Live && kind <= InstrumentKind::BassStack; }
inline bool isAmp(InstrumentKind kind) { return kind >= InstrumentKind::GuitarCombo && kind <= InstrumentKind::BassStack; }
inline bool isBus(InstrumentKind kind) { return kind == InstrumentKind::Bus; }
inline bool isMic(InstrumentKind kind) { return kind == InstrumentKind::Mic || kind == InstrumentKind::StereoMic; }
// A channel of two (a folder's or an aux's bus, a stereo mic's track): its inserts' plug-ins play in stereo.
inline bool isStereo(InstrumentKind kind) { return kind == InstrumentKind::Bus || kind == InstrumentKind::StereoMic; }
inline bool inRoom(InstrumentKind kind) { return !isBus(kind) && !isMic(kind); }  // heard in the room (and by its microphones)

class Instrument {
public:
    explicit Instrument(float sample_rate) : sr_(sample_rate) {}
    virtual ~Instrument() = default;

    // Adds the next `n` samples of this instrument into `out` (mono).
    virtual void render(float* out, int n) = 0;

    // Played live. The note sounds from the start of the next block.
    virtual void noteOn(int /*note*/, float /*velocity*/) {}
    virtual void noteOff(int /*note*/) {}
    virtual void sustain(bool /*pedal_down*/) {}
    virtual void controlChange(int /*controller*/, int /*value*/) {}  // a MIDI controller other than the sustain pedal
    virtual void pitchBend(int /*value*/) {}  // 0 to 16383, 8192 in the middle
    virtual void allNotesOff() {}  // releases everything that is being played live

    // Played by the sequencer: a note `dur_sec` long that starts `delay` samples into the coming block.
    virtual void play(int /*note*/, float /*dur_sec*/, float /*velocity*/, int /*delay*/) {}
    virtual void stopSequenced() {}  // fades out whatever the sequencer started
    // How much the loudness of each sequenced note varies, so a repeated note doesn't sound mechanical.
    virtual float velocityJitter() const { return 0.0f; }

    virtual void setInputChannel(int /*channel*/) {}  // live input only
    virtual void setInputEnabled(bool /*on*/) {}      // live input only
    // Live input only: what it takes in this block (its hardware input, before anything it does to it), for recording
    // (false if it has none); and recorded audio played back in its place, a block at a time from `feed` (or none),
    // heard through whatever the instrument does to its input, as a DAW plays a track back through its inserts.
    virtual bool readInput(float* /*out*/, int /*n*/) const { return false; }
    void setPlayback(const float* feed) { playback_ = feed; }

protected:
    float sr_;
    const float* playback_ = nullptr;
};

namespace voice {

// Oscillator with an exponential pitch drop and a percussive envelope (kick body, snare tone).
struct ToneHit {
    bool active = false, triangle = false;
    int delay = 0, t = 0, attack_len = 0, sweep_len = 0, end_len = 0;
    float phase = 0, freq = 0, freq_mul = 1, freq_end = 0, amp = 0, level = 0, decay_mul = 1, sr = 48000;

    void start(float sample_rate, int delay_samples, bool tri, float f0, float f1, float sweep_sec, float lvl, float decay_sec);
    float next();
};

// Filtered noise burst with an exponential decay (kick click, snare wires, hats).
struct NoiseHit {
    bool active = false;
    int delay = 0, t = 0, end_len = 0;
    float amp = 0, decay_mul = 1;
    Biquad filter;

    void start(float sample_rate, int delay_samples, Biquad::Type type, float freq, float q, float lvl, float decay_sec);
    float next(Rng& rng);
};

// A drum head's or a shell's mode: a sine that starts a little sharp and settles (a head goes flat as it relaxes after
// the hit), dying away over `decay_sec` (to -60 dB).
struct ModeHit {
    bool active = false;
    int delay = 0, t = 0, attack_len = 1, end_len = 0;
    float sr = 48000, phase = 0, freq = 0, freq_end = 0, glide_mul = 1, amp = 0, level = 0, decay_mul = 1;

    void start(float sample_rate, int delay_samples, float f_end, float sharp, float glide_sec, float lvl, float decay_sec);
    float next();
};

// A cymbal's metal: six square waves at clashing frequencies, as analog drum machines make their cymbals, with noise
// for sizzle, through a band-pass and a high-pass, dying away. Hats belong to `group` 1, so a closed hat can choke an
// open one that is still ringing, as the two cymbals of a real hi-hat do when they close.
struct MetalHit {
    bool active = false;
    int delay = 0, t = 0, end_len = 0, group = 0;
    float sr = 48000, amp = 0, decay_mul = 1, noise = 0;
    std::array<float, 6> phase{}, inc{};
    Biquad band, high;

    void start(float sample_rate, int delay_samples, float base, float band_freq, float high_freq, float lvl, float decay_sec,
               float noise_share, int grp);
    void choke(float decay_sec);  // dies away over this long from now instead
    // Struck again while still ringing: it rings on louder (the energies add) and starts dying away afresh.
    void restrike(float lvl, float decay_sec);
    float next(Rng& rng);
};

struct BassVoice {
    bool active = false, live = false;
    int note = -1, delay = 0, t = 0, attack_len = 0, hold_len = 0, release_len = 0, cutoff_len = 0;
    float sr = 48000, v = 0, amp = 0, decay_mul = 1, release_step = 0, cutoff = 0, cutoff_mul = 1;
    float sine_phase = 0, sine_inc = 0;
    SawOsc saw;
    Biquad lp;

    // dur_sec < 0: played live, so it holds (slowly dying away) until release().
    void start(float sample_rate, int delay_samples, int midi_note, float dur_sec, float velocity);
    void release();
    float next();
};

// One note of the pad: a detuned pair of saws through a low-pass that opens slowly and closes again.
struct PadVoice {
    bool active = false, live = false, released = false;
    int note = -1, delay = 0, t = 0, attack_len = 0, hold_len = 0, release_len = 0;
    int rise_len = 0, fall_start = -1, fall_len = 1, release_start = 0, release_span = 1;
    float sr = 48000, v = 0, amp = 0, release_from = 0, cutoff = 600, fall_from = 1900;
    std::array<SawOsc, 2> oscs;
    Biquad lp;

    // dur_sec < 0: played live, so it holds until release().
    void start(float sample_rate, int delay_samples, int midi_note, float dur_sec, float velocity, Rng& rng);
    void release();
    float next();
};

// Two-operator FM with an inharmonic ratio and a fast-decaying index: a soft bell.
struct BellVoice {
    bool active = false;
    int delay = 0, t = 0, attack_len = 0, index_len = 0, end_len = 0;
    float sr = 48000, f = 0, car_phase = 0, mod_phase = 0, dev = 0, dev_mul = 1, dev_end = 0, v = 0, amp = 0, decay_mul = 1;

    void start(float sample_rate, int delay_samples, float freq, float velocity);
    float next();
};

// The keys: 1:1 FM electric piano, two slightly detuned carriers. Sustains while held.
struct EPianoVoice {
    bool active = false, released = false, pedal_held = false, live = true;
    int note = -1, delay = 0, t = 0, attack_len = 0, index_len = 0, release_at = -1;
    float sr = 48000, f = 0, ph_a = 0, ph_b = 0, mod_phase = 0, dev = 0, dev_mul = 1, dev_end = 0;
    float amp = 0, peak = 0, hold_coef = 1, release_coef = 1;

    // release_after < 0: played live, so it holds until release().
    void start(float sample_rate, int midi_note, float velocity, int delay_samples = 0, int release_after = -1);
    void release() { released = true; }
    float next();
};

}  // namespace voice

// A drum machine. Every note plays one of its pieces, laid out like the General MIDI drum map and repeated in
// every octave, so any key on a controller does something.
class Drums : public Instrument {
public:
    enum Piece { Kick, Snare, HatClosed, HatOpen, TomLow, TomHigh, Clap, Crash, kPieces };
    static Piece pieceFor(int note);
    static int noteFor(Piece piece);  // the note a piece is written as in a pattern
    static const char* pieceName(Piece piece);

    using Instrument::Instrument;
    void hit(Piece piece, float velocity, int delay);
    void noteOn(int note, float velocity) override { hit(pieceFor(note), velocity, 0); }
    void play(int note, float /*dur_sec*/, float velocity, int delay) override { hit(pieceFor(note), velocity, delay); }
    void render(float* out, int n) override;

private:
    voice::ToneHit& toneSlot();
    voice::NoiseHit& noiseSlot();
    std::array<voice::ToneHit, 12> tones_;
    std::array<voice::NoiseHit, 24> noises_;
    Rng rng_;
};

// How an acoustic kit is tuned, damped and heard: the garage kit and the studio kit are the same kit voiced two ways.
struct KitVoicing {
    float kick_hz, kick_sharp, kick_decay, kick_boom, kick_beater;  // boom: the ring an undamped kick keeps; beater: its click
    float snare_hz, snare_decay, snare_ring, snare_ring_decay, snare_wires, snare_wire_decay;
    float rack_hz, floor_hz, rack_decay, floor_decay, tom_sharp;  // tom_sharp: how far a hard hit starts above the note
    float hat_noise, hat_band, cymbal_noise;                      // how much of a cymbal is noise rather than metal
    float buzz;                       // how much the snare's wires buzz along when the kick and toms are hit
    float tune_jitter, level_jitter;  // how far apart two hits can land
    float drive;                      // into a soft clip, as a kit recorded hot (1: clean)
    float room;                       // a small hard room's first reflections, heard with the kit (0: none)
};

// An acoustic drum kit. Each drum is its head's modes, settling in pitch after the hit, with the stick or beater on
// top; the snare's wires buzz along with the kick and toms; the hats choke when closed; the crash's and ride's washes
// build when hit again; harder hits are brighter, and no two hits are quite alike. The same eight pieces and keys as
// the drum machine, except that the clap's key (D#, as General MIDI's ride at 51) plays a ride.
class AcousticKit : public Instrument {
public:
    using Piece = Drums::Piece;
    static constexpr Piece Ride = Drums::Clap;  // the ride stands where the drum machine has its clap
    static int noteFor(Piece piece);
    static const char* pieceName(Piece piece);

    AcousticKit(float sample_rate, const KitVoicing& voicing);
    void hit(Piece piece, float velocity, int delay);
    void noteOn(int note, float velocity) override { hit(Drums::pieceFor(note), velocity, 0); }
    void play(int note, float /*dur_sec*/, float velocity, int delay) override { hit(Drums::pieceFor(note), velocity, delay); }
    float velocityJitter() const override { return 0.06f; }
    void render(float* out, int n) override;

private:
    void mode(int delay, float freq, float sharp, float glide, float level, float decay);
    void noise(int delay, Biquad::Type type, float freq, float q, float level, float decay);
    void metal(int delay, float base, float band, float high, float level, float decay, float noise_share, int group);
    // A cymbal's wash: one ring each for the ride and the crash, which a new hit adds to rather than piling up voices.
    void wash(voice::MetalHit& ring, int delay, float base, float band, float high, float level, float decay, float noise_share);
    KitVoicing v_;
    std::array<voice::ModeHit, 48> modes_;
    std::array<voice::NoiseHit, 24> noises_;
    std::array<voice::MetalHit, 12> metals_;
    voice::MetalHit ride_wash_, crash_wash_;
    Rng rng_{0x5DEECE66u};
    std::vector<float> scratch_, echoes_;  // the kit before the room and the drive; the room's memory
    size_t echo_at_ = 0;
};

// A rock kit in a garage, played loud: a kick barely damped, a ringing snare with loose wires, a rack tom and a floor
// tom left to ring, trashy hats, washy cymbals, a little crunch from being pushed, and the concrete walls slapping back.
class GarageKit : public AcousticKit {
public:
    explicit GarageKit(float sample_rate);
};

// The same kit in a studio, tuned and damped: a punchy kick with a clear beater, a tight snare, toms that sing and stop,
// clean hats and smooth cymbals, and nothing of the room but the one it stands in.
class StudioKit : public AcousticKit {
public:
    explicit StudioKit(float sample_rate);
};

class Bass : public Instrument {
public:
    using Instrument::Instrument;
    void noteOn(int note, float velocity) override;
    void noteOff(int note) override;
    void allNotesOff() override;
    void play(int note, float dur_sec, float velocity, int delay) override;
    void stopSequenced() override;
    void render(float* out, int n) override;

private:
    std::array<voice::BassVoice, 6> voices_;
};

class Pad : public Instrument {
public:
    using Instrument::Instrument;
    void noteOn(int note, float velocity) override;
    void noteOff(int note) override;
    void allNotesOff() override;
    void play(int note, float dur_sec, float velocity, int delay) override;
    void stopSequenced() override;
    void render(float* out, int n) override;

private:
    std::array<voice::PadVoice, 20> voices_;
    Rng rng_{0x2545F491u};
};

class Bells : public Instrument {
public:
    using Instrument::Instrument;
    void noteOn(int note, float velocity) override { strike(note, velocity, 0); }
    void play(int note, float /*dur_sec*/, float velocity, int delay) override { strike(note, velocity, delay); }
    float velocityJitter() const override { return 0.1f; }
    void render(float* out, int n) override;

private:
    void strike(int note, float velocity, int delay);
    std::array<voice::BellVoice, 12> voices_;
};

class Keys : public Instrument {
public:
    using Instrument::Instrument;
    void noteOn(int note, float velocity) override;
    void noteOff(int note) override;
    void sustain(bool pedal_down) override;
    void allNotesOff() override;
    void play(int note, float dur_sec, float velocity, int delay) override;
    void stopSequenced() override;
    void render(float* out, int n) override;

private:
    std::array<voice::EPianoVoice, 24> voices_;
    bool pedal_ = false;
};

// The audio captured for the block being rendered, one buffer per hardware input. Owned by the engine.
struct InputBus {
    static constexpr int kMaxChannels = 8;
    std::array<std::vector<float>, kMaxChannels> channel;
    int active = 0;  // how many inputs the open device delivers
};

// A bus's stand-in for an instrument: it plays nothing of its own (what it carries comes from the tracks routed to it).
class Silence : public Instrument {
public:
    using Instrument::Instrument;
    void render(float*, int) override {}
};

// Whatever is plugged into the audio input (a microphone, a guitar), placed in the room like any instrument.
// It plays one hardware input, or all of them added together.
class LiveInput : public Instrument {
public:
    static constexpr int kAllInputs = -1;
    LiveInput(float sample_rate, const InputBus* bus) : Instrument(sample_rate), bus_(bus) {}
    void setInputChannel(int channel) override { channel_ = channel; }
    void setInputEnabled(bool on) override { enabled_ = on; }  // off: silent, whatever comes in
    void render(float* out, int n) override {
        if (playback_)
            for (int i = 0; i < n; ++i) out[i] += playback_[i];
        if (enabled_) readInput(out, n);
    }
    bool readInput(float* out, int n) const override {  // adds its input into `out`
        if (!bus_) return false;
        const int first = channel_ < 0 ? 0 : channel_, last = channel_ < 0 ? bus_->active : channel_ + 1;
        for (int c = first; c < last && c < bus_->active; ++c) {
            const float* in = bus_->channel[size_t(c)].data();
            for (int i = 0; i < n; ++i) out[i] += in[i];
        }
        return true;
    }

private:
    const InputBus* bus_;
    int channel_ = kAllInputs;
    bool enabled_ = false;
};

}  // namespace sr
