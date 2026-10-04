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

// Listens to every MIDI source on the system, including ones plugged in later.
// `sink` runs on the system's MIDI thread, so it must not block (the engine pushes onto a lock-free queue).
class MidiInput {
public:
    using Sink = std::function<void(const MidiEvent&)>;

    MidiInput();
    ~MidiInput();

    bool start(Sink sink, std::string* error);
    void stop();
    // Connects to sources that appeared since the last call and forgets ones that went away.
    // The system also notifies us, but a host may call this now and then as a fallback.
    void rescan();
    std::vector<std::string> deviceNames() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace sr
