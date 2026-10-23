#pragma once

// Reading a sound between its samples. A microphone hears an instrument as late as the sound takes to reach it, which is
// seldom a whole number of samples: the sound has to be read part of the way from one sample to the next. A straight
// line between the two (linear interpolation) dulls the top octave, by as much as 3 dB at 12 kHz and 12 dB at 20 kHz
// halfway between, and by less nearer a sample, so a microphone's top end would change as it moved a few millimetres.
// These don't, or hardly.

namespace sr {

// A Kaiser-windowed sinc 16 samples long (β = 6): flat within 0.02 dB up to 18 kHz at 48 kHz wherever between two
// samples it reads, and at worst 0.6 dB down at 20 kHz; its phase that of the delay itself, so two microphones' sounds
// line up as their distances say. For what a microphone hears straight from each instrument.
struct Sinc16 {
    static constexpr int kTaps = 16;
    static constexpr int kBefore = 7;  // it reads from 7 samples before the one before where it reads...
    static constexpr int kAfter = 8;   // ...to 8 after (so whatever reads it waits that many samples)
    // Its 16 weights for reading `frac` (0 to 1) of the way from one sample to the next, for the samples from 7 before
    // the first to 8 after it. (Interpolated from a table of 256 fractions, made the first time it is asked for.)
    static void weights(float frac, float* out);
    static void prepare();  // (makes the table: call it somewhere other than the audio thread first)
};

// Lagrange's cubic through four samples, from the one before the first to the one after the second: 0.5 dB down at
// 10 kHz and 1 dB at 12 kHz halfway between, at a quarter of the sinc's cost. For the reflections, of which there are
// many, their highs mostly gone to the air and the walls.
inline void lagrange4(float d, float* out) {
    const float dm1 = d - 1.0f, dm2 = d - 2.0f, dp1 = d + 1.0f;
    out[0] = -d * dm1 * dm2 * (1.0f / 6.0f);
    out[1] = dp1 * dm1 * dm2 * 0.5f;
    out[2] = -dp1 * d * dm2 * 0.5f;
    out[3] = dp1 * d * dm1 * (1.0f / 6.0f);
}

}  // namespace sr
