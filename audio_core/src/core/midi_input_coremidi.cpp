// CoreMIDI backend (macOS).

#include "midi_input.h"

#include <algorithm>
#include <atomic>
#include <mutex>
#include <set>

#include <CoreMIDI/CoreMIDI.h>

namespace sr {

struct MidiInput::Impl {
    // One per source ever seen. Never freed while running: the MIDI thread holds a pointer to it.
    struct Entry {
        MIDIEndpointRef endpoint = 0;
        std::string name;
        bool present = true, enabled = true, connected = false;
        std::atomic<uint32_t> events{0};
    };

    MIDIClientRef client = 0;
    MIDIPortRef port = 0;
    Sink sink;
    mutable std::mutex mutex;  // guards the lists below; never taken on the MIDI or audio threads
    std::vector<std::unique_ptr<Entry>> entries;
    std::set<std::string> disabled;

    static std::string nameOf(MIDIEndpointRef src) {
        CFStringRef name = nullptr;
        char buf[256] = "MIDI device";
        if (MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr && name) {
            CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8);
            CFRelease(name);
        }
        return buf;
    }

    // MIDI 1.0 channel-voice messages arrive as 32-bit Universal MIDI Packets: 0x2G SS D1 D2.
    void handle(const MIDIEventList* list, Entry* from) const {
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
                } else if (status == 0xB0) {  // the mod wheel and the rest, for plug-in instruments
                    e.type = MidiEvent::Control;
                    e.note = d1;
                    e.value = d2;
                } else if (status == 0xE0) {
                    e.type = MidiEvent::PitchBend;
                    e.bend = uint16_t(d1 | (d2 << 7));
                } else {
                    continue;
                }
                if (from) from->events.fetch_add(1, std::memory_order_relaxed);
                sink(e);
            }
            packet = MIDIEventPacketNext(packet);
        }
    }

    void apply(Entry& e) {  // make the connection match `enabled`; call with the mutex held
        if (e.present && e.enabled && !e.connected) {
            e.connected = MIDIPortConnectSource(port, e.endpoint, &e) == noErr;
        } else if (e.connected && (!e.enabled || !e.present)) {
            if (e.present) MIDIPortDisconnectSource(port, e.endpoint);
            e.connected = false;
        }
    }

    void rescan() {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto& e : entries) e->present = false;
        const ItemCount n = MIDIGetNumberOfSources();
        for (ItemCount i = 0; i < n; ++i) {
            const MIDIEndpointRef src = MIDIGetSource(i);
            if (!src) continue;
            auto it = std::find_if(entries.begin(), entries.end(), [&](const auto& e) { return e->endpoint == src; });
            if (it == entries.end()) {
                auto entry = std::make_unique<Entry>();
                entry->endpoint = src;
                entry->name = nameOf(src);
                entry->enabled = disabled.count(entry->name) == 0;
                entries.push_back(std::move(entry));
                it = entries.end() - 1;
            }
            (*it)->present = true;
        }
        for (auto& e : entries) apply(*e);
    }
};

MidiInput::MidiInput() : impl_(std::make_unique<Impl>()) {}

MidiInput::~MidiInput() { stop(); }

bool MidiInput::start(Sink sink, std::string* error) {
    if (impl_->client) return true;
    impl_->sink = std::move(sink);
    Impl* impl = impl_.get();
    if (MIDIClientCreateWithBlock(CFSTR("Studiolator"), &impl->client, ^(const MIDINotification* message) {
            if (message->messageID == kMIDIMsgSetupChanged) impl->rescan();
        }) != noErr) {
        if (error) *error = "could not start MIDI";
        impl->client = 0;
        return false;
    }
    if (MIDIInputPortCreateWithProtocol(impl->client, CFSTR("Studiolator In"), kMIDIProtocol_1_0, &impl->port,
                                        ^(const MIDIEventList* list, void* source) {
                                            impl->handle(list, static_cast<Impl::Entry*>(source));
                                        }) != noErr) {
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
    impl_->entries.clear();  // safe now: the port is gone, so nothing can call back
}

void MidiInput::rescan() {
    if (impl_->port) impl_->rescan();
}

std::vector<MidiDeviceInfo> MidiInput::devices() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    std::vector<MidiDeviceInfo> out;
    for (const auto& e : impl_->entries)
        if (e->present) out.push_back({e->name, e->enabled, e->events.load(std::memory_order_relaxed)});
    return out;
}

void MidiInput::setEnabled(const std::string& name, bool enabled) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (enabled) impl_->disabled.erase(name);
    else impl_->disabled.insert(name);
    if (!impl_->port) return;
    for (auto& e : impl_->entries) {
        if (e->name != name) continue;
        e->enabled = enabled;
        impl_->apply(*e);
    }
}

}  // namespace sr
