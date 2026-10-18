#pragma once

// An instrument plug-in (an Audio Unit music device: a synthesizer, a sampler, a piano) standing in the room as an
// instrument. MIDI controllers, the computer keyboard and the sequencer play it as they play the built-in ones, and it
// hears them as MIDI: notes, the sustain pedal, the other controllers and pitch bend. A sequenced note can start
// partway into a block and lasts its length, its note-off sent when that comes round, to the sample.
// The game thread loads the plug-in and hands it over (AudioEngine::setInstrumentPlugin); until then it is silent.

#include <array>
#include <bitset>
#include <cstdint>

#include "instruments.h"

namespace sr {

class PluginInstance;

class PluginSynth : public Instrument {
public:
    using Instrument::Instrument;
    // Audio thread (or the game thread while the device is closed). Whatever was waiting to be sent is let go.
    void setPlugin(PluginInstance* plugin);
    void setBeatSamples(double beat_samples) { beat_samples_ = beat_samples; }  // the room's tempo, for the plug-in

    void noteOn(int note, float velocity) override;
    void noteOff(int note) override;
    void sustain(bool pedal_down) override;
    void controlChange(int controller, int value) override;
    void pitchBend(int value) override;
    void allNotesOff() override;
    void play(int note, float dur_sec, float velocity, int delay) override;
    void stopSequenced() override;
    void render(float* out, int n) override;

private:
    struct Event {
        int64_t at = 0;  // samples from the start of the coming block
        uint8_t status = 0, d1 = 0, d2 = 0;
        bool sequenced = false;
    };
    static constexpr int kMaxEvents = 512;
    void push(int64_t at, uint8_t status, uint8_t d1, uint8_t d2, bool sequenced);

    PluginInstance* plugin_ = nullptr;
    std::array<Event, kMaxEvents> events_;
    int count_ = 0;
    std::bitset<128> live_;  // keys held down live, to let go of together
    double beat_samples_ = 0.0;
};

}  // namespace sr
