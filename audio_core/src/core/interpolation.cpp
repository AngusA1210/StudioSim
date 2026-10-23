#include "interpolation.h"

#include <algorithm>
#include <array>
#include <cmath>

namespace sr {
namespace {

constexpr int kPhases = 256;

// I0, the modified Bessel function the Kaiser window is made of (its series, to well past float precision).
double besselI0(double x) {
    double sum = 1.0, term = 1.0;
    for (int k = 1; k < 40; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
    }
    return sum;
}

// Each fraction's weights (and one past the last, the next sample's), each set adding up to 1 so that nothing changes
// level.
using Table = std::array<std::array<float, Sinc16::kTaps>, kPhases + 1>;
const Table& table() {
    static const Table made = [] {
        Table t{};
        constexpr double beta = 6.0, pi = 3.14159265358979323846, half = Sinc16::kTaps / 2.0;
        for (int p = 0; p <= kPhases; ++p) {
            const double frac = double(p) / kPhases;
            double sum = 0.0;
            std::array<double, Sinc16::kTaps> w{};
            for (int n = 0; n < Sinc16::kTaps; ++n) {
                const double x = double(n - Sinc16::kBefore) - frac;
                const double sinc = std::fabs(x) < 1e-12 ? 1.0 : std::sin(pi * x) / (pi * x);
                const double edge = 1.0 - (x / half) * (x / half);
                w[size_t(n)] = sinc * besselI0(beta * std::sqrt(edge > 0.0 ? edge : 0.0)) / besselI0(beta);
                sum += w[size_t(n)];
            }
            for (int n = 0; n < Sinc16::kTaps; ++n) t[size_t(p)][size_t(n)] = float(w[size_t(n)] / sum);
        }
        return t;
    }();
    return made;
}

}  // namespace

void Sinc16::prepare() { (void)table(); }

void Sinc16::weights(float frac, float* out) {
    const Table& t = table();
    const float at = std::fmin(std::fmax(frac, 0.0f), 1.0f) * float(kPhases);
    const int p = std::min(int(at), kPhases - 1);
    const float f = at - float(p);
    const auto& a = t[size_t(p)];
    const auto& b = t[size_t(p + 1)];
    for (int n = 0; n < kTaps; ++n) out[n] = a[size_t(n)] + (b[size_t(n)] - a[size_t(n)]) * f;
}

}  // namespace sr
