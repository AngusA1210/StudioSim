#include "plugin_synth.h"

#include <algorithm>
#include <cmath>

#include "plugin_host.h"

namespace sr {
namespace {

uint8_t midiVelocity(float velocity) { return uint8_t(std::clamp(int(std::lround(velocity * 127.0f)), 1, 127)); }
uint8_t midiNote(int note) { return uint8_t(std::clamp(note, 0, 127)); }

}  // namespace

void PluginSynth::setPlugin(PluginInstance* plugin) {
    plugin_ = plugin;
    count_ = 0;
    live_.reset();
}

void PluginSynth::push(int64_t at, uint8_t status, uint8_t d1, uint8_t d2, bool sequenced) {
    if (count_ >= kMaxEvents) return;
    events_[size_t(count_++)] = Event{at, status, d1, d2, sequenced};
}

void PluginSynth::noteOn(int note, float velocity) {
    live_.set(midiNote(note));
    push(0, 0x90, midiNote(note), midiVelocity(velocity), false);
}

void PluginSynth::noteOff(int note) {
    live_.reset(midiNote(note));
    push(0, 0x80, midiNote(note), 0, false);
}

void PluginSynth::sustain(bool pedal_down) { push(0, 0xB0, 64, pedal_down ? 127 : 0, false); }

void PluginSynth::controlChange(int controller, int value) {
    push(0, 0xB0, uint8_t(std::clamp(controller, 0, 127)), uint8_t(std::clamp(value, 0, 127)), false);
}

void PluginSynth::pitchBend(int value) {
    value = std::clamp(value, 0, 16383);
    push(0, 0xE0, uint8_t(value & 0x7F), uint8_t(value >> 7), false);
}

void PluginSynth::allNotesOff() {
    for (int note = 0; note < 128; ++note)
        if (live_.test(size_t(note))) push(0, 0x80, uint8_t(note), 0, false);
    live_.reset();
    sustain(false);
}

void PluginSynth::play(int note, float dur_sec, float velocity, int delay) {
    const int64_t length = std::max<int64_t>(1, std::llround(double(dur_sec) * sr_));
    push(delay, 0x90, midiNote(note), midiVelocity(velocity), true);
    push(delay + length, 0x80, midiNote(note), 0, true);
}

// The sequencer stopped: notes it had yet to start never do, and those it started are let go now.
void PluginSynth::stopSequenced() {
    int kept = 0;
    for (int i = 0; i < count_; ++i) {
        Event e = events_[size_t(i)];
        if (e.sequenced && e.status == 0x90) continue;
        if (e.sequenced) e.at = 0;
        events_[size_t(kept++)] = e;
    }
    count_ = kept;
}

void PluginSynth::render(float* out, int n) {
    if (!plugin_) {
        count_ = 0;
        return;
    }
    if (beat_samples_ > 0.0) plugin_->setTempo(60.0 * sr_ / beat_samples_);
    // What falls in this block goes to the plug-in in the order it was played (so a note-off and the next note-on on
    // the same sample keep their order); the rest waits.
    int kept = 0;
    for (int i = 0; i < count_; ++i) {
        Event e = events_[size_t(i)];
        if (e.at < n) {
            plugin_->midi(e.status, e.d1, e.d2, int(std::max<int64_t>(e.at, 0)));
        } else {
            e.at -= n;
            events_[size_t(kept++)] = e;
        }
    }
    count_ = kept;
    plugin_->render(out, n);
}

}  // namespace sr
