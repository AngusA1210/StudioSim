#pragma once

// Guitar and bass amplifiers: a head (a preamp that can be driven into distortion, a three-band tone stack and
// presence), a master volume, and a speaker cabinet. Any head goes with any cabinet, and either can be bypassed:
// without its head an amp plays what reaches it straight through the cabinet (an amp simulator on a pedal in front
// can be the head), and without its cabinet it is a flat, full-range speaker.
//
//   heads      Clean (lots of headroom), Crunch (clean to crunchy), High Gain (two gain stages, tight lows),
//              Bass Round (deep, gentle drive), Bass Punch (punchy, more top end and drive)
//   cabinets   1x12 and 2x12 open-back, 4x12 closed-back, 1x15, 4x10 and 8x10 for bass
//
// The four kinds of amp in the room start as a Crunch head in a 1x12 combo, a High Gain head on a 4x12, a Bass Round
// 1x15 combo and a Bass Punch head on an 8x10.
//
// The cabinets are how the speakers sound in the room, heard as you would standing in front of them rather than as a
// microphone up against the cone hears them: no close-miking's boomy lows or bright peak, just the speakers' own
// response, which is the speaker's to the room. They are filters, rather than recorded impulses, so they cost almost
// nothing. The drive stages run at twice the sample rate so the distortion doesn't fold harsh tones back down.
// In front of each amp is a board of effect pedals (pedals.h), the loop pedal among them if it has one: the input
// goes through them in order, and the amp plays what comes out. The last of them can be in the amp's effects loop
// instead: a series loop, as most amps have one, sent out after the preamp and its tone stack and returned before the
// power amp (its presence and master), so a delay or a reverb there repeats the amp's distortion rather than being
// distorted by it.

#include <array>
#include <vector>

#include "dsp.h"
#include "instruments.h"
#include "pedals.h"

namespace sr {

// The amp's knobs, each 0 to 10 as on the panel. 5 leaves the tone controls flat.
enum class AmpControl : int { Gain, Bass, Mid, Treble, Presence, Master, kCount };
constexpr int kAmpControls = int(AmpControl::kCount);

enum class AmpHead : int { Clean, Crunch, HighGain, BassRound, BassPunch, kCount };
enum class AmpCabinet : int { OpenBack1x12, OpenBack2x12, Closed4x12, Bass1x15, Bass4x10, Bass8x10, kCount };
constexpr int kAmpHeads = int(AmpHead::kCount), kAmpCabinets = int(AmpCabinet::kCount);
AmpHead defaultHead(InstrumentKind kind);
AmpCabinet defaultCabinet(InstrumentKind kind);

class AmpModel {
public:
    void init(InstrumentKind kind, float sample_rate);  // with that kind's head and cabinet
    void setHead(AmpHead head, bool on);
    void setCabinet(AmpCabinet cabinet, bool on);
    void setControl(AmpControl control, float value);  // 0 to 10
    void process(float* io, int n) {
        preamp(io, n);
        power(io, n);
    }
    // The two halves either side of the effects loop: the preamp (its drive and tone stack), and the power amp (its
    // presence and master) and the cabinet.
    void preamp(float* io, int n);
    void power(float* io, int n);

private:
    struct Voicing {
        float input_cut;        // high-pass before the preamp (Hz)
        float tight;            // how much of the lows are kept out of the drive, 0 to 1
        float max_drive_db;     // preamp gain with Gain at 10
        int stages;             // gain stages: one, or two for high gain
        float bass_hz, mid_hz, treble_hz, presence_hz;
        float out_trim;         // evens out the loudness: a plucked string at -20 dBFS RMS comes out at about -18
    };
    void updateFilters();
    void voiceCabinet();
    float drive(float x);  // the preamp at twice the sample rate, back down again

    AmpHead head_ = AmpHead::Crunch;
    AmpCabinet cabinet_kind_ = AmpCabinet::OpenBack1x12;
    bool head_on_ = true, cabinet_on_ = true;
    Voicing v_{};
    float sr_ = 48000.0f;
    std::array<float, kAmpControls> knobs_{5, 5, 5, 5, 5, 5};
    float drive_gain_ = 1.0f, master_ = 1.0f, master_now_ = 1.0f;
    Biquad input_cut_, tight_cut_, interstage_;
    Biquad up_[2], down_[2];  // the oversampling filters
    Biquad bass_, mid_, treble_, presence_;
    std::array<Biquad, 5> cabinet_;
    int cabinet_stages_ = 0;
};

// An amp in the room: plays its hardware input (when its input is on) through its pedals and the amp model.
class Amp : public Instrument {
public:
    Amp(float sample_rate, InstrumentKind kind, const InputBus* bus, int max_block);
    void setInputChannel(int channel) override { channel_ = channel; }
    void setInputEnabled(bool on) override { enabled_ = on; }
    void setControl(AmpControl control, float value) { model_.setControl(control, value); }
    void setHead(AmpHead head, bool on) { model_.setHead(head, on); }
    void setCabinet(AmpCabinet cabinet, bool on) { model_.setCabinet(cabinet, on); }
    // The pedals belong to the source, so that they outlive the amp being rebuilt; `timing` is where the engine
    // keeps the bar lines for this block (samples to the next one, or -1, and a bar's length).
    void connect(const PedalBoard* board, const int64_t* timing) {
        board_ = board;
        timing_ = timing;
    }
    void render(float* out, int n) override;
    bool readInput(float* out, int n) const override;  // what is plugged in, before the pedals and the amp

private:
    AmpModel model_;
    const InputBus* bus_;
    const PedalBoard* board_ = nullptr;
    const int64_t* timing_ = nullptr;
    int channel_ = -1;
    bool enabled_ = false;
    std::vector<float> in_;
};

}  // namespace sr
