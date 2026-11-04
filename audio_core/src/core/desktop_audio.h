#pragma once

// Desktop audio, as an audio bridge: what the computer's other apps play (a browser, a music player, a call), taken in
// as two more inputs beside the interface's (InputBus's kDesktop...), for a Speaker or an amp in the room to play,
// as Pro Tools' Audio Bridge brings a Mac's sound into its mixer. StudioSim's own sound is left out of it, so nothing
// it plays comes round again.
//
// On a Mac (macOS 14.2 or later) it is a Core Audio process tap on every other app's sound, which is muted where it
// would have played while StudioSim takes it: the computer's sound goes through StudioSim, and only there, as through
// a bridge, until it is switched off or StudioSim quits, when it plays as it did. The first time, macOS asks whether
// StudioSim may record the computer's audio (the app's NSAudioCaptureUsageDescription says why). On Windows it is
// WASAPI's loopback of the default output (Windows 10 2004 or later leaving StudioSim's own sound out), which goes on
// playing there too: set Windows' sound to an output you aren't listening to (one the interface doesn't use, say),
// and it is heard through StudioSim alone.
//
// It comes at its own rate, on its own clock (the computer's own output's), and is read between its samples at the
// engine's, a touch faster while more is held than it aims to hold and a touch slower while less (0.2 % at most), as
// the sound of the other players is (net_audio.h): two clocks never quite agree.
//
// Two threads: the platform's capture thread writes what comes in (lock-free rings); the audio thread reads it.
// The game thread starts and stops it.

#include <atomic>
#include <memory>
#include <string>

#include "float_ring.h"

namespace sr {

class DesktopAudio {
public:
    DesktopAudio();
    ~DesktopAudio();
    DesktopAudio(const DesktopAudio&) = delete;
    DesktopAudio& operator=(const DesktopAudio&) = delete;

    // The game thread. False, with why, if it couldn't (an older system, no output to take it from). Without
    // `capture`, it is fed by captured() alone (the checks).
    bool start(std::string* error, bool capture = true);
    void stop();
    bool running() const { return running_.load(std::memory_order_acquire); }

    // The audio thread: `n` samples of each side at `engine_rate` (silence while it fills up, or while it is off).
    // True while it is on.
    bool read(float* left, float* right, int n, double engine_rate);
    float heldMs() const { return held_ms_.load(std::memory_order_relaxed); }

    // The platform's capture thread: `frames` of what came in, its two sides interleaved, at `rate`.
    void captured(const float* stereo, int frames, double rate);

    struct Platform;  // (each platform's own: desktop_audio_mac.mm, or desktop_audio.cpp)

private:
    bool startPlatform(std::string* error);
    void stopPlatform();

    std::unique_ptr<Platform> platform_;
    FloatRing ring_{1 << 17};             // its two sides interleaved, so that they never come apart
    std::atomic<bool> running_{false};
    std::atomic<bool> fresh_{false};      // started again: the audio thread lets go of what was left from before
    std::atomic<double> rate_{48000.0};   // what it comes in at
    std::atomic<int> chunk_{0};           // the most that has come in at once
    std::atomic<float> held_ms_{0.0f};
    // The audio thread's
    double frac_ = 0.0;
    float fill_error_ = 0.0f;
    bool waiting_ = true;
};

}  // namespace sr
