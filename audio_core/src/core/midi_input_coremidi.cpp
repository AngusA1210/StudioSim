// CoreMIDI backend (macOS).

#include "midi_input.h"

#include <algorithm>
#include <mutex>

#include <CoreMIDI/CoreMIDI.h>

namespace sr {

struct MidiInput::Impl {
    MIDIClientRef client = 0;
    MIDIPortRef port = 0;
    Sink sink;
    mutable std::mutex mutex;  // guards `connected`; never taken on the MIDI or audio threads
    std::vector<MIDIEndpointRef> connected;

    // MIDI 1.0 channel-voice messages arrive as 32-bit Universal MIDI Packets: 0x2G SS D1 D2.
    void handle(const MIDIEventList* list) const {
        const MIDIEventPacket* packet = &list->packet[0];
        for (UInt32 p = 0; p < list->numPackets; ++p) {
            for (UInt32 w = 0; w < packet->wordCount; ++w) {
                const UInt32 word = packet->words[w];
                if ((word >> 28) != 0x2) continue;
                const uint8_t status = (word >> 16) & 0xF0, d1 = (word >> 8) & 0x7F, d2 = word & 0x7F;
                MidiEvent e;
                if (status == 0x90 && d2 > 0) {
                    e.type = MidiEvent::NoteOn;
                    e.note = d1;
                    e.velocity = float(d2) / 127.0f;
                } else if (status == 0x80 || status == 0x90) {
                    e.type = MidiEvent::NoteOff;
                    e.note = d1;
                } else if (status == 0xB0 && d1 == 64) {
                    e.type = MidiEvent::Sustain;
                    e.note = d2 >= 64 ? 1 : 0;
                } else {
                    continue;
                }
                sink(e);
            }
            packet = MIDIEventPacketNext(packet);
        }
    }

    void rescan() {
        std::lock_guard<std::mutex> lock(mutex);
        std::vector<MIDIEndpointRef> present;
        const ItemCount n = MIDIGetNumberOfSources();
        for (ItemCount i = 0; i < n; ++i) {
            const MIDIEndpointRef src = MIDIGetSource(i);
            if (!src) continue;
            present.push_back(src);
            if (std::find(connected.begin(), connected.end(), src) == connected.end() &&
                MIDIPortConnectSource(port, src, nullptr) == noErr)
                connected.push_back(src);
        }
        connected.erase(std::remove_if(connected.begin(), connected.end(),
                                       [&](MIDIEndpointRef e) {
                                           return std::find(present.begin(), present.end(), e) == present.end();
                                       }),
                        connected.end());
    }
};

MidiInput::MidiInput() : impl_(std::make_unique<Impl>()) {}

MidiInput::~MidiInput() { stop(); }

bool MidiInput::start(Sink sink, std::string* error) {
    if (impl_->client) return true;
    impl_->sink = std::move(sink);
    Impl* impl = impl_.get();
    if (MIDIClientCreateWithBlock(CFSTR("SoundRoom"), &impl->client, ^(const MIDINotification* message) {
            if (message->messageID == kMIDIMsgSetupChanged) impl->rescan();
        }) != noErr) {
        if (error) *error = "could not start MIDI";
        impl->client = 0;
        return false;
    }
    if (MIDIInputPortCreateWithProtocol(impl->client, CFSTR("SoundRoom In"), kMIDIProtocol_1_0, &impl->port,
                                        ^(const MIDIEventList* list, void*) { impl->handle(list); }) != noErr) {
        if (error) *error = "could not open a MIDI input port";
        stop();
        return false;
    }
    impl->rescan();
    return true;
}

void MidiInput::stop() {
    if (impl_->port) MIDIPortDispose(impl_->port);
    if (impl_->client) MIDIClientDispose(impl_->client);
    impl_->port = 0;
    impl_->client = 0;
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->connected.clear();
}

void MidiInput::rescan() {
    if (impl_->port) impl_->rescan();
}

std::vector<std::string> MidiInput::deviceNames() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    std::vector<std::string> names;
    for (MIDIEndpointRef src : impl_->connected) {
        CFStringRef name = nullptr;
        char buf[256] = "MIDI device";
        if (MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr && name) {
            CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8);
            CFRelease(name);
        }
        names.emplace_back(buf);
    }
    return names;
}

}  // namespace sr
