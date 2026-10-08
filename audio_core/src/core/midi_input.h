#pragma once

// MIDI controllers, read directly by the audio core so notes skip the game's frame loop.

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace sr {

struct MidiEvent {
    enum Type : uint8_t { NoteOn, NoteOff, Sustain };
    Type type = NoteOn;
    uint8_t note = 0;       // for Sustain: non-zero means the pedal is down
    float velocity = 0.0f;  // 0..1
};

struct MidiDeviceInfo {
    std::string name;
    bool enabled = true;   // we are listening to it
    uint32_t events = 0;   // notes and pedal moves received so far, for an activity light
};

// Sees every MIDI source on the system, including ones plugged in later, and listens to the enabled ones.
// `sink` runs on the system's MIDI thread, so it must not block (the engine pushes onto a lock-free queue).
class MidiInput {
public:
    using Sink = std::function<void(const MidiEvent&)>;

    MidiInput();
    ~MidiInput();

    bool start(Sink sink, std::string* error);
    void stop();
    // Picks up sources that appeared since the last call and drops ones that went away.
    // The system also notifies us, but a host may call this now and then as a fallback.
    void rescan();
    std::vector<MidiDeviceInfo> devices() const;
    // New devices are listened to unless they were disabled by name (this is remembered across re-plugging).
    void setEnabled(const std::string& name, bool enabled);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace sr
