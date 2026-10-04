// Placeholder for platforms without a MIDI backend yet (Windows and Linux are still to do).

#include "midi_input.h"

namespace sr {

struct MidiInput::Impl {};

MidiInput::MidiInput() : impl_(std::make_unique<Impl>()) {}
MidiInput::~MidiInput() = default;

bool MidiInput::start(Sink, std::string* error) {
    if (error) *error = "MIDI input is not implemented on this platform yet";
    return false;
}
void MidiInput::stop() {}
void MidiInput::rescan() {}
std::vector<std::string> MidiInput::deviceNames() const { return {}; }

}  // namespace sr
