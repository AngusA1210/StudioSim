#pragma once

// Guitar and bass amplifiers: a preamp that can be driven into distortion, a three-band tone stack, presence, a
// master volume, and the speaker cabinet's own tone. Four of them, as combos and as heads on cabinets:
//
//   guitar combo   one 12" speaker in an open-back cabinet: clean to crunchy
//   guitar stack   a high-gain head on a closed 4x12: two gain stages, tight lows
//   bass combo     one 15" speaker: deep and round, gentle drive
//   bass stack     a head on an 8x10: punchy, with more top end and more drive
//
// The drive stages run at twice the sample rate so the distortion doesn't fold harsh tones back down. The cabinets
// are filters shaped like a speaker's response rather than recorded impulses, so they cost almost nothing.
// A loop pedal (looper.h) sits in front of each amp; the amp plays the live input and the loop together.

#include <array>
#include <vector>

#include "dsp.h"
#include "instruments.h"
#include "looper.h"

namespace sr {

// The amp's knobs, each 0 to 10 as on the panel. 5 leaves the tone controls flat.
enum class AmpControl : int { Gain, Bass, Mid, Treble, Presence, Master, kCount };
constexpr int kAmpControls = int(AmpControl::kCount);

class AmpModel {
public:
    void init(InstrumentKind kind, float sample_rate);
    void setControl(AmpControl control, float value);  // 0 to 10
    void process(float* io, int n);

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
    float drive(float x);  // the preamp at twice the sample rate, back down again

    InstrumentKind kind_ = InstrumentKind::GuitarCombo;
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

// An amp in the room: plays its hardware input (when its input is on) and its loop pedal, through the amp model.
class Amp : public Instrument {
public:
    Amp(float sample_rate, InstrumentKind kind, const InputBus* bus, int max_block);
    void setInputChannel(int channel) override { channel_ = channel; }
    void setInputEnabled(bool on) override { enabled_ = on; }
    void setControl(AmpControl control, float value) { model_.setControl(control, value); }
    // The loop pedal belongs to the source, so that it outlives the amp being rebuilt; `timing` is where the engine
    // keeps the bar lines for this block (samples to the next one, or -1, and a bar's length).
    void connect(Looper* looper, const int64_t* timing) {
        looper_ = looper;
        timing_ = timing;
    }
    void render(float* out, int n) override;

private:
    AmpModel model_;
    const InputBus* bus_;
    Looper* looper_ = nullptr;
    const int64_t* timing_ = nullptr;
    int channel_ = -1;
    bool enabled_ = false;
    std::vector<float> in_, signal_;
};

}  // namespace sr
