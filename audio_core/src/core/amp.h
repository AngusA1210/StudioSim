#pragma once

// Guitar and bass amplifiers: a head (a preamp that can be driven into distortion and its three-band tone stack, then a
// power amp: presence, the master driving the output tubes), and a speaker cabinet with its speakers. Any head goes with
// any cabinet, any speaker of the cabinet's size in it, and either can be bypassed: without its head an amp plays what
// reaches it straight through the cabinet (an amp simulator on a pedal in front can be the head), and without its
// cabinet it is a flat, full-range speaker.
//
// The power amp is a push-pull pair of output tubes: turned up (the master), they saturate as they reach full power,
// softly and evenly (odd harmonics), and the supply sags under a sustained load (a tube rectifier's most), so the full
// power it can give dips for a moment and the note blooms. A head's wattage against what its speakers carry decides
// whether the speakers can be driven past their rating: then they compress as their voice coils heat, and their cones
// distort, as a small combo turned up does.
//
//   heads      Clean (lots of headroom), Crunch (clean to crunchy), High Gain (two gain stages, tight lows),
//              Bass Round (deep, gentle drive), Bass Punch (punchy, more top end and drive)
//   cabinets   1x12 and 2x12 open-back, 4x12 closed-back, 1x15, 4x10 and 8x10 for bass
//   speakers   12": British 25 W (warm, soft-topped), British 60 W (an aggressive upper-mid bite), American
//              vintage (scooped, sparkly, loose lows), British alnico (chiming, bright); 10": American 10 (bright,
//              tight), Bass 10 (punchy, extended); 15": Bass 15 (deep, soft on top)
//
// The four kinds of amp in the room start as a Crunch head in a 1x12 combo, a High Gain head on a 4x12, a Bass Round
// 1x15 combo and a Bass Punch head on an 8x10.
//
// A cabinet and its speakers are how they sound in the room on the speakers' axis, far enough off to be past their near
// field, as a maker measures a speaker: the box's low end (a closed back holds more of it), the speaker's resonance,
// its breakup peaks in the upper mids and how fast it falls away above them. How they sound from anywhere else, close up
// or off axis, is the room's to work out from where the cones are (radiation.h). They are filters, rather than recorded
// impulses, so they cost almost nothing. The drive stages run at twice the sample rate so their distortion doesn't fold
// harsh tones back down.
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
enum class AmpSpeaker : int { British25, British60, AmericanVintage, BritishAlnico, American10, Bass10, Bass15, kCount };
constexpr int kAmpHeads = int(AmpHead::kCount), kAmpCabinets = int(AmpCabinet::kCount), kAmpSpeakers = int(AmpSpeaker::kCount);
AmpHead defaultHead(InstrumentKind kind);
AmpCabinet defaultCabinet(InstrumentKind kind);
AmpSpeaker defaultSpeaker(AmpCabinet cabinet);
int cabinetSpeakers(AmpCabinet cabinet);  // how many speakers it holds
float cabinetInches(AmpCabinet cabinet);  // and their size
float headWatts(AmpHead head);            // what its power amp gives at full power

// A speaker: its size (inches, as sold), what one carries (watts), and as the room hears it (radiation.h) where its
// cone starts to break up and how much brighter it is right in front of its dust cap.
struct SpeakerInfo {
    float inches, watts, breakup_hz, cap_db;
};
SpeakerInfo speakerInfo(AmpSpeaker speaker);

class AmpModel {
public:
    void init(InstrumentKind kind, float sample_rate);  // with that kind's head and cabinet
    void setHead(AmpHead head, bool on);
    void setCabinet(AmpCabinet cabinet, bool on);  // with its usual speaker, unless the one it has is the right size
    void setSpeaker(AmpSpeaker speaker);           // (one of another size than the cabinet's is ignored)
    AmpSpeaker speaker() const { return speaker_; }
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
        float headroom;         // the power amp's full power, as an amplitude (the master at 5 keeps a plucked string well under it)
        float sag;              // how far the supply droops under a sustained load, at full power (0 to 1)
    };
    void updateFilters();
    void voiceCabinet();
    void voiceSpeaker();
    float drive(float x);      // the preamp at twice the sample rate, back down again
    float powerAmp(float x);   // the output tubes, likewise
    float speakers(float x);   // the speakers' compression and their cones' distortion, driven past their rating

    AmpHead head_ = AmpHead::Crunch;
    AmpCabinet cabinet_kind_ = AmpCabinet::OpenBack1x12;
    AmpSpeaker speaker_ = AmpSpeaker::AmericanVintage;
    bool head_on_ = true, cabinet_on_ = true;
    Voicing v_{};
    float sr_ = 48000.0f;
    std::array<float, kAmpControls> knobs_{5, 5, 5, 5, 5, 5};
    float drive_gain_ = 1.0f, master_ = 1.0f, master_now_ = 1.0f;
    Biquad input_cut_, tight_cut_, interstage_;
    Biquad up_[2], down_[2];  // the oversampling filters
    Biquad power_up_[2], power_down_[2];
    Biquad bass_, mid_, treble_, presence_;
    std::array<Biquad, 2> cabinet_;  // the box: its low end
    std::array<Biquad, 6> speaker_eq_;  // the speaker: its mids and top
    int speaker_stages_ = 0;
    float sag_ = 0.0f, sag_attack_ = 0.0f, sag_release_ = 0.0f;  // the supply's load, followed
    float heat_ = 0.0f, heat_coef_ = 0.0f;                         // the speakers' voice coils' heat, followed (slowly)
    float speaker_full_ = 1.0f;  // where the speakers reach their rating, against the power amp's full power
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
    void setSpeaker(AmpSpeaker speaker) { model_.setSpeaker(speaker); }
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
