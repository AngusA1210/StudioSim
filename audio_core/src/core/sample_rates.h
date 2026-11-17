#pragma once

// The sample rates StudioSim runs at: 44.1 and 48 kHz, the two Steam Audio's binaural rendering (its HRTF) is made
// for; it can't be made at 88.2, 96, 176.4 or 192 kHz. An interface set to one of those is asked to change to the rate
// StudioSim runs at, as a DAW sets an interface to its session's rate; if it won't, what StudioSim plays is converted
// to its rate on the way out (and its inputs to StudioSim's on the way in).

namespace sr {

inline bool engineRateSupported(int rate) { return rate == 44100 || rate == 48000; }

// The rate to run at: the one asked for (`wanted`, 0 for none); or else the interface's own, if StudioSim can run at
// it; or else the one of the two its rate is a multiple of (88.2 and 176.4 kHz are 44.1's), 48 kHz otherwise.
inline int chooseEngineRate(int wanted, int device_rate) {
    if (engineRateSupported(wanted)) return wanted;
    if (engineRateSupported(device_rate)) return device_rate;
    return device_rate > 0 && device_rate % 44100 == 0 ? 44100 : 48000;
}

}  // namespace sr
