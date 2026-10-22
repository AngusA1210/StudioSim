#include "amp.h"

#include <cmath>

namespace sr {
namespace {

float dbToGain(float db) { return std::pow(10.0f, db / 20.0f); }

// A tube-like soft clip: rounder on one side than the other, which adds the even harmonics that make an amp warm.
inline float tube(float x) {
    constexpr float kBias = 0.18f;
    return std::tanh(x + kBias) - std::tanh(kBias);
}

// Shelving and peaking filters (RBJ cookbook), not in dsp.h because only the amps use them.
void lowShelf(Biquad& f, float sr, float hz, float db) {
    const float a = std::pow(10.0f, db / 40.0f), w = kTwoPi * hz / sr, c = std::cos(w), s = std::sin(w);
    const float alpha = s / 2.0f * std::sqrt(2.0f), k = 2.0f * std::sqrt(a) * alpha;
    const float a0 = (a + 1) + (a - 1) * c + k;
    f.b0 = a * ((a + 1) - (a - 1) * c + k) / a0;
    f.b1 = 2 * a * ((a - 1) - (a + 1) * c) / a0;
    f.b2 = a * ((a + 1) - (a - 1) * c - k) / a0;
    f.a1 = -2 * ((a - 1) + (a + 1) * c) / a0;
    f.a2 = ((a + 1) + (a - 1) * c - k) / a0;
}

void highShelf(Biquad& f, float sr, float hz, float db) {
    const float a = std::pow(10.0f, db / 40.0f), w = kTwoPi * hz / sr, c = std::cos(w), s = std::sin(w);
    const float alpha = s / 2.0f * std::sqrt(2.0f), k = 2.0f * std::sqrt(a) * alpha;
    const float a0 = (a + 1) - (a - 1) * c + k;
    f.b0 = a * ((a + 1) + (a - 1) * c + k) / a0;
    f.b1 = -2 * a * ((a - 1) + (a + 1) * c) / a0;
    f.b2 = a * ((a + 1) + (a - 1) * c - k) / a0;
    f.a1 = 2 * ((a - 1) - (a + 1) * c) / a0;
    f.a2 = ((a + 1) - (a - 1) * c - k) / a0;
}

void peak(Biquad& f, float sr, float hz, float q, float db) {
    const float a = std::pow(10.0f, db / 40.0f), w = kTwoPi * hz / sr, alpha = std::sin(w) / (2.0f * q), c = std::cos(w);
    const float a0 = 1 + alpha / a;
    f.b0 = (1 + alpha * a) / a0;
    f.b1 = -2 * c / a0;
    f.b2 = (1 - alpha * a) / a0;
    f.a1 = -2 * c / a0;
    f.a2 = (1 - alpha / a) / a0;
}

}  // namespace

AmpHead defaultHead(InstrumentKind kind) {
    switch (kind) {
        case InstrumentKind::GuitarStack: return AmpHead::HighGain;
        case InstrumentKind::BassCombo: return AmpHead::BassRound;
        case InstrumentKind::BassStack: return AmpHead::BassPunch;
        default: return AmpHead::Crunch;
    }
}

AmpCabinet defaultCabinet(InstrumentKind kind) {
    switch (kind) {
        case InstrumentKind::GuitarStack: return AmpCabinet::Closed4x12;
        case InstrumentKind::BassCombo: return AmpCabinet::Bass1x15;
        case InstrumentKind::BassStack: return AmpCabinet::Bass8x10;
        default: return AmpCabinet::OpenBack1x12;
    }
}

AmpSpeaker defaultSpeaker(AmpCabinet cabinet) {
    switch (cabinet) {
        case AmpCabinet::OpenBack2x12: return AmpSpeaker::BritishAlnico;
        case AmpCabinet::Closed4x12: return AmpSpeaker::British60;
        case AmpCabinet::Bass1x15: return AmpSpeaker::Bass15;
        case AmpCabinet::Bass4x10:
        case AmpCabinet::Bass8x10: return AmpSpeaker::Bass10;
        default: return AmpSpeaker::AmericanVintage;
    }
}

int cabinetSpeakers(AmpCabinet cabinet) {
    switch (cabinet) {
        case AmpCabinet::OpenBack2x12: return 2;
        case AmpCabinet::Closed4x12:
        case AmpCabinet::Bass4x10: return 4;
        case AmpCabinet::Bass8x10: return 8;
        default: return 1;
    }
}

float cabinetInches(AmpCabinet cabinet) {
    switch (cabinet) {
        case AmpCabinet::Bass1x15: return 15.0f;
        case AmpCabinet::Bass4x10:
        case AmpCabinet::Bass8x10: return 10.0f;
        default: return 12.0f;
    }
}

float headWatts(AmpHead head) {
    switch (head) {
        case AmpHead::Clean: return 85.0f;      // a big clean combo's
        case AmpHead::HighGain: return 100.0f;
        case AmpHead::BassRound: return 300.0f;
        case AmpHead::BassPunch: return 500.0f;
        default: return 30.0f;                  // a small crunchy combo's
    }
}

// {inches, watts, breakup, dust cap's bite}, as a speaker's maker would give them (of the kinds, not of any one maker).
SpeakerInfo speakerInfo(AmpSpeaker speaker) {
    switch (speaker) {
        case AmpSpeaker::British25: return {12.0f, 25.0f, 1000.0f, 3.0f};
        case AmpSpeaker::British60: return {12.0f, 60.0f, 1200.0f, 5.0f};
        case AmpSpeaker::BritishAlnico: return {12.0f, 15.0f, 1300.0f, 4.0f};
        case AmpSpeaker::American10: return {10.0f, 25.0f, 1400.0f, 4.0f};
        case AmpSpeaker::Bass10: return {10.0f, 250.0f, 1100.0f, 3.0f};
        case AmpSpeaker::Bass15: return {15.0f, 400.0f, 700.0f, 2.0f};
        default: return {12.0f, 20.0f, 1100.0f, 4.0f};  // American vintage
    }
}

void AmpModel::init(InstrumentKind kind, float sample_rate) {
    sr_ = sample_rate;
    for (auto* f : {&input_cut_, &tight_cut_, &interstage_, &up_[0], &up_[1], &down_[0], &down_[1], &bass_, &mid_, &treble_, &presence_})
        f->reset();
    for (int i = 0; i < 2; ++i) {  // fourth-order low-passes just under the original Nyquist frequency
        for (Biquad* f : {&up_[i], &down_[i], &power_up_[i], &power_down_[i]}) {
            f->reset();
            f->set(Biquad::Lowpass, sr_ * 2, sr_ * 0.45f, i == 0 ? 0.54f : 1.31f);
        }
    }
    for (auto& f : cabinet_) f.reset();
    for (auto& f : speaker_eq_) f.reset();
    sag_ = heat_ = 0.0f;
    sag_attack_ = 1.0f - std::exp(-1.0f / (0.03f * sr_));    // the supply droops over a few tens of milliseconds
    sag_release_ = 1.0f - std::exp(-1.0f / (0.15f * sr_));   // and recovers over a tenth of a second or so
    heat_coef_ = 1.0f - std::exp(-1.0f / (1.5f * sr_));     // voice coils heat and cool over a second or two
    setHead(defaultHead(kind), true);
    setCabinet(defaultCabinet(kind), true);
    setSpeaker(defaultSpeaker(defaultCabinet(kind)));
    master_now_ = master_;
}

void AmpModel::setHead(AmpHead head, bool on) {
    head_ = head;
    head_on_ = on;
    // {input cut, tight, drive at 10, stages, bass, mid, treble, presence, trim, headroom, sag}: the trims leave a
    // plucked string at -20 dBFS coming out at about -18 dBFS with the knobs at 5, through the head's usual cabinet. A
    // big clean amp has headroom to spare and a solid supply; a small crunchy one little, and a tube rectifier's sag.
    switch (head) {
        case AmpHead::Clean:     v_ = {70.0f, 0.15f, 22.0f, 1, 140.0f, 550.0f, 3200.0f, 5000.0f, 0.444f, 1.2f, 0.05f}; break;
        case AmpHead::HighGain:  v_ = {90.0f, 0.75f, 52.0f, 2, 180.0f, 700.0f, 2800.0f, 4500.0f, 0.139f, 0.7f, 0.1f}; break;
        case AmpHead::BassRound: v_ = {30.0f, 0.0f, 24.0f, 1, 70.0f, 450.0f, 2200.0f, 3500.0f, 0.582f, 0.9f, 0.25f}; break;
        case AmpHead::BassPunch: v_ = {35.0f, 0.2f, 32.0f, 1, 80.0f, 500.0f, 2500.0f, 4000.0f, 0.327f, 1.0f, 0.1f}; break;
        default:                 v_ = {80.0f, 0.4f, 36.0f, 1, 200.0f, 650.0f, 3000.0f, 5000.0f, 0.254f, 0.5f, 0.3f}; break;
    }
    input_cut_.set(Biquad::Highpass, sr_, v_.input_cut, 0.707f);
    tight_cut_.set(Biquad::Highpass, sr_ * 2, 650.0f, 0.6f);
    interstage_.set(Biquad::Lowpass, sr_ * 2, 7000.0f, 0.6f);
    updateFilters();
    voiceSpeaker();  // (how hard it can drive them)
}

void AmpModel::setCabinet(AmpCabinet cabinet, bool on) {
    cabinet_kind_ = cabinet;
    cabinet_on_ = on;
    if (speakerInfo(speaker_).inches != cabinetInches(cabinet)) speaker_ = defaultSpeaker(cabinet);
    voiceCabinet();
    voiceSpeaker();
}

void AmpModel::setSpeaker(AmpSpeaker speaker) {
    if (speakerInfo(speaker).inches != cabinetInches(cabinet_kind_)) return;
    speaker_ = speaker;
    voiceSpeaker();
}

// The box: the low end it gives its speakers (a closed back holds more of it; an open back less, its back cancelling
// some of the front's lows far off, which the room works out), and its resonance.
void AmpModel::voiceCabinet() {
    switch (cabinet_kind_) {
        case AmpCabinet::Closed4x12:
            cabinet_[0].set(Biquad::Highpass, sr_, 75.0f, 0.9f);
            peak(cabinet_[1], sr_, 110.0f, 1.2f, 3.0f);
            break;
        case AmpCabinet::OpenBack2x12:
            cabinet_[0].set(Biquad::Highpass, sr_, 80.0f, 0.75f);
            peak(cabinet_[1], sr_, 130.0f, 1.0f, 2.0f);
            break;
        case AmpCabinet::Bass1x15:
            cabinet_[0].set(Biquad::Highpass, sr_, 38.0f, 0.8f);
            peak(cabinet_[1], sr_, 80.0f, 1.0f, 2.0f);
            break;
        case AmpCabinet::Bass4x10:
            cabinet_[0].set(Biquad::Highpass, sr_, 50.0f, 0.8f);
            peak(cabinet_[1], sr_, 110.0f, 1.0f, 2.0f);
            break;
        case AmpCabinet::Bass8x10:
            cabinet_[0].set(Biquad::Highpass, sr_, 45.0f, 0.8f);
            peak(cabinet_[1], sr_, 100.0f, 1.0f, 3.0f);
            break;
        default:  // a 1x12 open back: lighter lows
            cabinet_[0].set(Biquad::Highpass, sr_, 88.0f, 0.7f);
            peak(cabinet_[1], sr_, 150.0f, 1.0f, 2.0f);
            break;
    }
}

// The speaker, on its axis: its mids (a dip, a bump), its breakup peaks in the upper mids, and how fast it falls away
// above them (two low-passes). Peaks are kept to the few decibels a speaker really has, without a close microphone's
// exaggeration (that is the room's to add, from where the mic is). And how hard the head can drive them.
void AmpModel::voiceSpeaker() {
    int n = 0;
    auto bump = [&](float hz, float q, float db) { peak(speaker_eq_[size_t(n++)], sr_, hz, q, db); };
    auto top = [&](float hz, float q) { speaker_eq_[size_t(n++)].set(Biquad::Lowpass, sr_, hz, q); };
    switch (speaker_) {
        case AmpSpeaker::British25:  // warm and mid-forward, a soft top
            bump(1800.0f, 0.8f, 1.5f);
            bump(2700.0f, 1.4f, 3.0f);
            top(4700.0f, 0.75f);
            top(5200.0f, 0.6f);
            break;
        case AmpSpeaker::British60:  // the low mids pulled back, an aggressive upper-mid bite
            bump(1100.0f, 1.0f, -2.0f);
            bump(2500.0f, 1.2f, 4.0f);
            bump(4000.0f, 2.5f, 2.0f);
            top(5200.0f, 0.8f);
            top(5600.0f, 0.6f);
            break;
        case AmpSpeaker::BritishAlnico:  // chiming, bright, sweet
            bump(1200.0f, 1.0f, 1.0f);
            bump(3000.0f, 1.0f, 3.0f);
            bump(5000.0f, 2.0f, 1.5f);
            top(6500.0f, 0.8f);
            top(7000.0f, 0.6f);
            break;
        case AmpSpeaker::American10:  // bright and tight
            bump(1000.0f, 1.0f, -1.0f);
            bump(3500.0f, 1.0f, 3.0f);
            top(6000.0f, 0.75f);
            top(7000.0f, 0.6f);
            break;
        case AmpSpeaker::Bass10:  // punchy, a growl in the mids, extended
            bump(1800.0f, 1.0f, 2.0f);
            top(5000.0f, 0.7f);
            top(6500.0f, 0.6f);
            break;
        case AmpSpeaker::Bass15:  // deep, soft on top
            bump(800.0f, 1.0f, 1.0f);
            top(3000.0f, 0.7f);
            top(3500.0f, 0.6f);
            break;
        default:  // American vintage: scooped, a sparkly top
            bump(700.0f, 0.8f, -1.5f);
            bump(3200.0f, 1.0f, 3.5f);
            top(6000.0f, 0.75f);
            top(6500.0f, 0.6f);
            break;
    }
    speaker_stages_ = n;
    // Where the speakers reach their rating, as a share of the power amp's full power: the power goes as the square.
    const SpeakerInfo info = speakerInfo(speaker_);
    speaker_full_ = std::sqrt(float(cabinetSpeakers(cabinet_kind_)) * info.watts / (head_on_ ? headWatts(head_) : 50.0f));
}

void AmpModel::setControl(AmpControl control, float value) {
    knobs_[size_t(control)] = std::clamp(value, 0.0f, 10.0f);
    updateFilters();
}

void AmpModel::updateFilters() {
    const auto knob = [&](AmpControl c) { return knobs_[size_t(c)]; };
    drive_gain_ = dbToGain(knob(AmpControl::Gain) / 10.0f * v_.max_drive_db);
    lowShelf(bass_, sr_, v_.bass_hz, (knob(AmpControl::Bass) - 5.0f) * 2.4f);
    peak(mid_, sr_, v_.mid_hz, 0.7f, (knob(AmpControl::Mid) - 5.0f) * 2.4f);
    highShelf(treble_, sr_, v_.treble_hz, (knob(AmpControl::Treble) - 5.0f) * 2.4f);
    highShelf(presence_, sr_, v_.presence_hz, (knob(AmpControl::Presence) - 5.0f) * 1.2f);
    const float m = knob(AmpControl::Master) / 5.0f;
    master_ = m * m;  // 5 is unity, 10 is +12 dB, 0 is silence
}

float AmpModel::drive(float x) {
    float result = 0.0f;
    for (int phase = 0; phase < 2; ++phase) {  // up to twice the rate: the sample, then a zero, filtered
        float y = up_[1].process(up_[0].process(phase == 0 ? 2.0f * x : 0.0f));
        // Keep some of the lows out of the drive, so it distorts tightly rather than into mud.
        y = (1.0f - v_.tight) * y + v_.tight * tight_cut_.process(y);
        y = tube(y * drive_gain_);
        if (v_.stages > 1) y = tube(interstage_.process(y) * 3.0f);
        y = down_[1].process(down_[0].process(y));
        if (phase == 0) result = y;  // and back down: keep every other sample
    }
    return result;
}

// The output tubes, at twice the sample rate as the preamp is: driven by the master, they give out softly as they reach
// full power (a push-pull pair not quite matched: a touch of the even harmonics too), and the full power they can give
// falls as the supply sags under a sustained load. Below full power they pass what they are given, unchanged.
float AmpModel::powerAmp(float x) {
    constexpr float kBias = 0.06f;
    const float full = v_.headroom * (1.0f - v_.sag * std::min(sag_ / v_.headroom, 1.0f));
    const float rest = kBias / std::sqrt(1.0f + kBias * kBias);
    float result = 0.0f;
    for (int phase = 0; phase < 2; ++phase) {
        float y = power_up_[1].process(power_up_[0].process(phase == 0 ? 2.0f * x : 0.0f));
        const float u = y / full + kBias;
        y = full * (u / std::sqrt(1.0f + u * u) - rest);
        y = power_down_[1].process(power_down_[0].process(y));
        if (phase == 0) result = y;
    }
    const float load = std::fabs(result);
    sag_ += (load - sag_) * (load > sag_ ? sag_attack_ : sag_release_);
    return result;
}

// The speakers, driven past their rating: their voice coils heat and they give less (slowly, up to a few decibels),
// and their cones distort as they reach the end of their travel. Within their rating they barely do either.
float AmpModel::speakers(float x) {
    const float rated = std::max(speaker_full_ * (head_on_ ? v_.headroom : 1.0f), 1e-3f);
    const float driven = x / rated;
    heat_ += (driven * driven - heat_) * heat_coef_;
    const float u = driven / (1.0f + 0.3f * heat_) / 1.4f;
    return 1.4f * rated * u / std::sqrt(std::sqrt(1.0f + u * u * u * u));
}

void AmpModel::preamp(float* io, int n) {
    if (!head_on_) return;
    for (int i = 0; i < n; ++i) io[i] = treble_.process(mid_.process(bass_.process(drive(input_cut_.process(io[i]))))) * v_.out_trim;
}

void AmpModel::power(float* io, int n) {
    for (int i = 0; i < n; ++i) {
        master_now_ += (master_ - master_now_) * 0.002f;  // the master is the amp's volume, with or without its head
        float x = io[i];
        if (head_on_) x = powerAmp(presence_.process(x) * master_now_);
        else x *= master_now_;
        if (cabinet_on_) {
            x = speakers(x);
            for (auto& f : cabinet_) x = f.process(x);
            for (int c = 0; c < speaker_stages_; ++c) x = speaker_eq_[size_t(c)].process(x);
        }
        io[i] = x;
    }
}

Amp::Amp(float sample_rate, InstrumentKind kind, const InputBus* bus, int max_block)
    : Instrument(sample_rate), bus_(bus), in_(size_t(max_block), 0.0f), dry_(size_t(max_block), 0.0f) {
    model_.init(kind, sample_rate);
}

bool Amp::readInput(float* out, int n) const {  // as the Speaker takes it in: one input, or all of them together
    if (!bus_) return false;
    const int first = channel_ < 0 ? 0 : channel_, last = channel_ < 0 ? bus_->active : channel_ + 1;
    for (int c = first; c < last && c < bus_->active; ++c) {
        const float* in = bus_->channel[size_t(c)].data();
        for (int i = 0; i < n; ++i) out[i] += in[i];
    }
    return true;
}

void Amp::render(float* out, int n) {
    n = std::min(n, int(in_.size()));
    std::fill(in_.begin(), in_.begin() + n, 0.0f);
    if (enabled_) readInput(in_.data(), n);
    if (playback_)  // a recording of the guitar, played back through the pedals and the amp again
        for (int i = 0; i < n; ++i) in_[size_t(i)] += playback_[i];
    // Through the pedals in front of it, in order, then the preamp; through those in its effects loop, blended with the
    // preamp's own signal as its Mix has it, then the power amp and the cabinet.
    PedalTiming timing;
    if (timing_) timing = {double(timing_[1]) / 4.0, timing_[0], timing_[1]};
    const int count = board_ ? board_->count : 0, front = board_ ? std::min(board_->front, count) : 0;
    for (int p = 0; p < front; ++p) board_->pedals[size_t(p)]->process(in_.data(), n, timing);
    model_.preamp(in_.data(), n);
    if (front < count) {
        std::copy(in_.begin(), in_.begin() + n, dry_.begin());
        for (int p = front; p < count; ++p) board_->pedals[size_t(p)]->process(in_.data(), n, timing);
        for (int i = 0; i < n; ++i) in_[size_t(i)] = dry_[size_t(i)] + (in_[size_t(i)] - dry_[size_t(i)]) * loop_mix_;
    }
    model_.power(in_.data(), n);
    for (int i = 0; i < n; ++i) out[i] += in_[size_t(i)];
}

}  // namespace sr
