// Windows MIDI backend (the system's own, WinMM): every MIDI input the system lists, each opened by its name. Windows
// doesn't say when one is plugged in or out, so a rescan (the game makes one every few seconds) picks up the changes.

#include "midi_input.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mmsystem.h>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <set>

namespace sr {

struct MidiInput::Impl {
    // One per input ever seen, by name. Never freed while running: the MIDI callback holds a pointer to it.
    struct Entry {
        std::string name;
        UINT index = 0;  // where the system lists it just now
        HMIDIIN handle = nullptr;
        bool present = true, enabled = true;
        std::atomic<uint32_t> events{0};
        Impl* owner = nullptr;
    };

    Sink sink;
    bool running = false;
    mutable std::mutex mutex;  // guards the lists below; never taken on the MIDI or audio threads
    std::vector<std::unique_ptr<Entry>> entries;
    std::set<std::string> disabled;

    static std::string utf8(const wchar_t* w) {
        const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
        std::string out(size_t(std::max(n - 1, 0)), '\0');
        if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w, -1, out.data(), n, nullptr, nullptr);
        return out;
    }

    // A channel-voice message, as WinMM packs one: status, then its two data bytes.
    static void CALLBACK received(HMIDIIN, UINT message, DWORD_PTR instance, DWORD_PTR packed, DWORD_PTR) {
        if (message != MIM_DATA) return;
        auto* from = reinterpret_cast<Entry*>(instance);
        const uint8_t status = uint8_t(packed & 0xF0), d1 = uint8_t((packed >> 8) & 0x7F), d2 = uint8_t((packed >> 16) & 0x7F);
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
            return;
        }
        from->events.fetch_add(1, std::memory_order_relaxed);
        from->owner->sink(e);
    }

    void apply(Entry& e) {  // open or close it to match `enabled`; call with the mutex held
        if (e.present && e.enabled && !e.handle) {
            HMIDIIN handle = nullptr;
            if (midiInOpen(&handle, e.index, reinterpret_cast<DWORD_PTR>(&Impl::received), reinterpret_cast<DWORD_PTR>(&e),
                           CALLBACK_FUNCTION) == MMSYSERR_NOERROR) {
                midiInStart(handle);
                e.handle = handle;
            }
        } else if (e.handle && (!e.enabled || !e.present)) {
            midiInStop(e.handle);
            midiInReset(e.handle);
            midiInClose(e.handle);
            e.handle = nullptr;
        }
    }

    void rescan() {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto& e : entries) e->present = false;
        std::vector<std::string> seen;
        const UINT n = midiInGetNumDevs();
        for (UINT i = 0; i < n; ++i) {
            MIDIINCAPSW caps{};
            if (midiInGetDevCapsW(i, &caps, sizeof(caps)) != MMSYSERR_NOERROR) continue;
            std::string name = utf8(caps.szPname);
            const int twins = int(std::count(seen.begin(), seen.end(), name));  // (two of one kind: "Keyboard 2")
            seen.push_back(name);
            if (twins > 0) name += " " + std::to_string(twins + 1);
            auto it = std::find_if(entries.begin(), entries.end(), [&](const auto& e) { return e->name == name; });
            if (it == entries.end()) {
                auto entry = std::make_unique<Entry>();
                entry->name = name;
                entry->owner = this;
                entry->enabled = disabled.count(name) == 0;
                entries.push_back(std::move(entry));
                it = entries.end() - 1;
            }
            if ((*it)->handle && (*it)->index != i) {  // listed somewhere else now: opened again there
                (*it)->present = false;
                apply(**it);
            }
            (*it)->index = i;
            (*it)->present = true;
        }
        for (auto& e : entries) apply(*e);
    }

    void closeAll() {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto& e : entries) {
            e->present = false;
            apply(*e);
        }
    }
};

MidiInput::MidiInput() : impl_(std::make_unique<Impl>()) {}

MidiInput::~MidiInput() { stop(); }

bool MidiInput::start(Sink sink, std::string*) {
    if (impl_->running) return true;
    impl_->sink = std::move(sink);
    impl_->running = true;
    impl_->rescan();
    return true;
}

void MidiInput::stop() {
    if (!impl_->running) return;
    impl_->closeAll();
    impl_->running = false;
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->entries.clear();  // safe now: every input is closed, so nothing can call back
}

void MidiInput::rescan() {
    if (impl_->running) impl_->rescan();
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
    if (!impl_->running) return;
    for (auto& e : impl_->entries) {
        if (e->name != name) continue;
        e->enabled = enabled;
        impl_->apply(*e);
    }
}

}  // namespace sr
