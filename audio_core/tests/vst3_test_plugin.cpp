// A VST3 plug-in for the checks alone, so that they never load anyone's own plug-ins: two classes, written straight
// against the VST 3 interfaces (no SDK helper classes, so it needs none of the SDK's base library).
//
//   "SR Test Gain"  an effect: one channel or two, a Gain parameter (normalized 0.5 = unity, 1 = +6 dB), its settings the
//                   gain; a controller in the same object (a "single component" plug-in).
//   "SR Test Tone"  an instrument: a sine at the pitch of the last note held, silent once it is let go; its sustain
//                   pedal (controller 64) mapped to a parameter that holds the note.
//   "SR Test Echo"  an effect: what it hears, and again a second later at half its level (Mix, normalized: 0.5),
//                   no repeats; in the checks where an echo shows where a plug-in plays.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/vstspeaker.h"

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#endif

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

const FUID kGainId(0x5352A001, 0x7E5D4C2B, 0x9A6B1C0D, 0x2E3F4051);
const FUID kToneId(0x5352A002, 0x7E5D4C2B, 0x9A6B1C0D, 0x2E3F4051);
const FUID kEchoId(0x5352A003, 0x7E5D4C2B, 0x9A6B1C0D, 0x2E3F4051);
const FUID kLookaheadId(0x5352A004, 0x7E5D4C2B, 0x9A6B1C0D, 0x2E3F4051);
const FUID kSquashId(0x5352A005, 0x7E5D4C2B, 0x9A6B1C0D, 0x2E3F4051);
constexpr double kSquashRangeDb = 48.0;  // SR Test Squash's threshold, and its gain reduction meter, go down this far
constexpr int kLookahead = 1000;  // samples: how late SR Test Lookahead plays what it hears, and says so

void copy128(String128 to, const char* from) {
    int i = 0;
    for (; from[i] && i < 127; ++i) to[i] = char16(from[i]);
    to[i] = 0;
}

// What both have in common: a component that is its own controller, with parameters as `count` normalized values.
class Plugin : public U::Implements<U::Directly<IComponent, IAudioProcessor, IEditController, IMidiMapping>> {
public:
    tresult PLUGIN_API initialize(FUnknown*) override { return kResultOk; }
    tresult PLUGIN_API terminate() override { return kResultOk; }
    // IComponent
    tresult PLUGIN_API getControllerClassId(TUID) override { return kNotImplemented; }
    tresult PLUGIN_API setIoMode(IoMode) override { return kResultOk; }
    tresult PLUGIN_API getRoutingInfo(RoutingInfo&, RoutingInfo&) override { return kNotImplemented; }
    tresult PLUGIN_API activateBus(MediaType, BusDirection, int32, TBool) override { return kResultOk; }
    tresult PLUGIN_API setActive(TBool) override { return kResultOk; }
    tresult PLUGIN_API setState(IBStream* state) override { return readState(state); }
    tresult PLUGIN_API getState(IBStream* state) override {
        int32 written = 0;
        return state->write(values_, int32(sizeof(float) * count()), &written);
    }
    // IAudioProcessor
    tresult PLUGIN_API canProcessSampleSize(int32 size) override { return size == kSample32 ? kResultTrue : kResultFalse; }
    uint32 PLUGIN_API getLatencySamples() override { return 0; }
    tresult PLUGIN_API setupProcessing(ProcessSetup& setup) override {
        sample_rate_ = setup.sampleRate;
        return kResultOk;
    }
    tresult PLUGIN_API setProcessing(TBool) override { return kResultOk; }
    uint32 PLUGIN_API getTailSamples() override { return 0; }
    // IEditController
    tresult PLUGIN_API setComponentState(IBStream* state) override { return readState(state); }  // (setState and getState
                                                                                               // are the component's)
    int32 PLUGIN_API getParameterCount() override { return count(); }
    ParamValue PLUGIN_API getParamNormalized(ParamID id) override { return id < ParamID(count()) ? values_[id] : 0.0; }
    tresult PLUGIN_API setParamNormalized(ParamID id, ParamValue value) override {
        if (id >= ParamID(count())) return kInvalidArgument;
        values_[id] = float(value);
        return kResultOk;
    }
    tresult PLUGIN_API getParamValueByString(ParamID, TChar*, ParamValue&) override { return kNotImplemented; }
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID, ParamValue value) override { return value; }
    ParamValue PLUGIN_API plainParamToNormalized(ParamID, ParamValue value) override { return value; }
    tresult PLUGIN_API setComponentHandler(IComponentHandler*) override { return kResultOk; }
    IPlugView* PLUGIN_API createView(FIDString) override { return nullptr; }
    tresult PLUGIN_API getMidiControllerAssignment(int32, int16, CtrlNumber, ParamID&) override { return kResultFalse; }

protected:
    virtual int count() const = 0;
    tresult readState(IBStream* state) {
        int32 read = 0;
        float v[4] = {};
        if (state->read(v, int32(sizeof(float) * count()), &read) != kResultOk || read != int32(sizeof(float) * count())) return kResultFalse;
        std::memcpy(values_, v, sizeof(float) * size_t(count()));
        return kResultOk;
    }
    // The last value each parameter is given in this block.
    void takeChanges(ProcessData& data) {
        if (!data.inputParameterChanges) return;
        for (int32 i = 0; i < data.inputParameterChanges->getParameterCount(); ++i) {
            IParamValueQueue* q = data.inputParameterChanges->getParameterData(i);
            int32 offset = 0;
            ParamValue value = 0;
            if (q && q->getPointCount() > 0 && q->getPoint(q->getPointCount() - 1, offset, value) == kResultOk &&
                q->getParameterId() < ParamID(count()))
                values_[q->getParameterId()] = float(value);
        }
    }
    float values_[4] = {};
    double sample_rate_ = 48000.0;
};

class Gain final : public Plugin {
public:
    Gain() { values_[0] = 0.5f; }
    int32 PLUGIN_API getBusCount(MediaType type, BusDirection) override { return type == kAudio ? 1 : 0; }
    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& bus) override {
        if (type != kAudio || index != 0) return kInvalidArgument;
        bus.mediaType = kAudio;
        bus.direction = dir;
        bus.channelCount = SpeakerArr::getChannelCount(arrangement_);
        copy128(bus.name, dir == kInput ? "In" : "Out");
        bus.busType = kMain;
        bus.flags = BusInfo::kDefaultActive;
        return kResultOk;
    }
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement* ins, int32 nin, SpeakerArrangement* outs, int32 nout) override {
        if (nin != 1 || nout != 1 || ins[0] != outs[0] || (ins[0] != SpeakerArr::kMono && ins[0] != SpeakerArr::kStereo)) return kResultFalse;
        arrangement_ = ins[0];
        return kResultTrue;
    }
    tresult PLUGIN_API getBusArrangement(BusDirection, int32 index, SpeakerArrangement& arr) override {
        if (index != 0) return kInvalidArgument;
        arr = arrangement_;
        return kResultOk;
    }
    tresult PLUGIN_API process(ProcessData& data) override {
        takeChanges(data);
        if (data.numInputs < 1 || data.numOutputs < 1) return kResultOk;
        const float gain = 2.0f * values_[0];
        for (int32 c = 0; c < data.outputs[0].numChannels; ++c) {
            const float* in = data.inputs[0].channelBuffers32[std::min(c, data.inputs[0].numChannels - 1)];
            float* out = data.outputs[0].channelBuffers32[c];
            for (int32 i = 0; i < data.numSamples; ++i) out[i] = in[i] * gain;
        }
        return kResultOk;
    }
    tresult PLUGIN_API getParameterInfo(int32 index, ParameterInfo& info) override {
        if (index != 0) return kInvalidArgument;
        info = {};
        info.id = 0;
        copy128(info.title, "Gain");
        copy128(info.shortTitle, "Gain");
        copy128(info.units, "dB");
        info.defaultNormalizedValue = 0.5;
        info.flags = ParameterInfo::kCanAutomate;
        return kResultOk;
    }
    tresult PLUGIN_API getParamStringByValue(ParamID id, ParamValue value, String128 text) override {
        if (id != 0) return kInvalidArgument;
        char s[32];
        std::snprintf(s, sizeof(s), "%+.1f", value > 0.0 ? 20.0 * std::log10(2.0 * value) : -96.0);
        copy128(text, s);
        return kResultOk;
    }

protected:
    int count() const override { return 1; }

private:
    SpeakerArrangement arrangement_ = SpeakerArr::kStereo;
};

class Echo final : public Plugin {
public:
    Echo() { values_[0] = 0.5f; }
    int32 PLUGIN_API getBusCount(MediaType type, BusDirection) override { return type == kAudio ? 1 : 0; }
    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& bus) override {
        if (type != kAudio || index != 0) return kInvalidArgument;
        bus.mediaType = kAudio;
        bus.direction = dir;
        bus.channelCount = SpeakerArr::getChannelCount(arrangement_);
        copy128(bus.name, dir == kInput ? "In" : "Out");
        bus.busType = kMain;
        bus.flags = BusInfo::kDefaultActive;
        return kResultOk;
    }
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement* ins, int32 nin, SpeakerArrangement* outs, int32 nout) override {
        if (nin != 1 || nout != 1 || ins[0] != outs[0] || (ins[0] != SpeakerArr::kMono && ins[0] != SpeakerArr::kStereo)) return kResultFalse;
        arrangement_ = ins[0];
        return kResultTrue;
    }
    tresult PLUGIN_API getBusArrangement(BusDirection, int32 index, SpeakerArrangement& arr) override {
        if (index != 0) return kInvalidArgument;
        arr = arrangement_;
        return kResultOk;
    }
    tresult PLUGIN_API setupProcessing(ProcessSetup& setup) override {
        sample_rate_ = setup.sampleRate;
        for (auto& line : lines_) line.assign(size_t(setup.sampleRate), 0.0f);  // a second
        at_ = 0;
        return kResultOk;
    }
    tresult PLUGIN_API process(ProcessData& data) override {
        takeChanges(data);
        if (data.numInputs < 1 || data.numOutputs < 1 || lines_[0].empty()) return kResultOk;
        const size_t length = lines_[0].size();
        size_t at = at_;
        for (int32 c = 0; c < data.outputs[0].numChannels && c < 2; ++c) {
            const float* in = data.inputs[0].channelBuffers32[std::min(c, data.inputs[0].numChannels - 1)];
            float* out = data.outputs[0].channelBuffers32[c];
            std::vector<float>& line = lines_[size_t(c)];
            at = at_;
            for (int32 i = 0; i < data.numSamples; ++i) {
                const float x = in[i];
                out[i] = x + values_[0] * line[at];
                line[at] = x;
                at = (at + 1) % length;
            }
        }
        at_ = at;
        return kResultOk;
    }
    tresult PLUGIN_API getParameterInfo(int32 index, ParameterInfo& info) override {
        if (index != 0) return kInvalidArgument;
        info = {};
        info.id = 0;
        copy128(info.title, "Mix");
        copy128(info.units, "%");
        info.defaultNormalizedValue = 0.5;
        info.flags = ParameterInfo::kCanAutomate;
        return kResultOk;
    }
    tresult PLUGIN_API getParamStringByValue(ParamID, ParamValue value, String128 text) override {
        char s[16];
        std::snprintf(s, sizeof(s), "%.0f", value * 100.0);
        copy128(text, s);
        return kResultOk;
    }

protected:
    int count() const override { return 1; }

private:
    SpeakerArrangement arrangement_ = SpeakerArr::kStereo;
    std::vector<float> lines_[2];
    size_t at_ = 0;
};

// A plug-in that makes its sound late and reports by how much, as a lookahead limiter or a linear-phase EQ does: what
// it hears, kLookahead samples later, otherwise untouched.
class Lookahead final : public Plugin {
public:
    int32 PLUGIN_API getBusCount(MediaType type, BusDirection) override { return type == kAudio ? 1 : 0; }
    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& bus) override {
        if (type != kAudio || index != 0) return kInvalidArgument;
        bus.mediaType = kAudio;
        bus.direction = dir;
        bus.channelCount = SpeakerArr::getChannelCount(arrangement_);
        copy128(bus.name, dir == kInput ? "In" : "Out");
        bus.busType = kMain;
        bus.flags = BusInfo::kDefaultActive;
        return kResultOk;
    }
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement* ins, int32 nin, SpeakerArrangement* outs, int32 nout) override {
        if (nin != 1 || nout != 1 || ins[0] != outs[0] || (ins[0] != SpeakerArr::kMono && ins[0] != SpeakerArr::kStereo)) return kResultFalse;
        arrangement_ = ins[0];
        return kResultTrue;
    }
    tresult PLUGIN_API getBusArrangement(BusDirection, int32 index, SpeakerArrangement& arr) override {
        if (index != 0) return kInvalidArgument;
        arr = arrangement_;
        return kResultOk;
    }
    uint32 PLUGIN_API getLatencySamples() override { return kLookahead; }
    tresult PLUGIN_API setupProcessing(ProcessSetup&) override {
        for (auto& line : lines_) line.assign(size_t(kLookahead), 0.0f);
        at_ = 0;
        return kResultOk;
    }
    tresult PLUGIN_API process(ProcessData& data) override {
        if (data.numInputs < 1 || data.numOutputs < 1 || lines_[0].empty()) return kResultOk;
        size_t at = at_;
        for (int32 c = 0; c < data.outputs[0].numChannels && c < 2; ++c) {
            const float* in = data.inputs[0].channelBuffers32[std::min(c, data.inputs[0].numChannels - 1)];
            float* out = data.outputs[0].channelBuffers32[c];
            std::vector<float>& line = lines_[size_t(c)];
            at = at_;
            for (int32 i = 0; i < data.numSamples; ++i) {
                const float x = in[i];
                out[i] = line[at];
                line[at] = x;
                at = (at + 1) % line.size();
            }
        }
        at_ = at;
        return kResultOk;
    }
    tresult PLUGIN_API getParameterInfo(int32, ParameterInfo&) override { return kInvalidArgument; }
    tresult PLUGIN_API getParamStringByValue(ParamID, ParamValue, String128) override { return kInvalidArgument; }

protected:
    int count() const override { return 0; }

private:
    SpeakerArrangement arrangement_ = SpeakerArr::kStereo;
    std::vector<float> lines_[2];
    size_t at_ = 0;
};

class Tone final : public Plugin {
public:
    int32 PLUGIN_API getBusCount(MediaType type, BusDirection dir) override { return dir == kOutput ? (type == kAudio ? 1 : 0) : (type == kEvent ? 1 : 0); }
    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& bus) override {
        if (index != 0) return kInvalidArgument;
        bus.mediaType = type;
        bus.direction = dir;
        bus.channelCount = type == kAudio ? 2 : 16;
        copy128(bus.name, type == kAudio ? "Out" : "MIDI");
        bus.busType = kMain;
        bus.flags = BusInfo::kDefaultActive;
        return kResultOk;
    }
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement*, int32 nin, SpeakerArrangement* outs, int32 nout) override {
        return nin == 0 && nout == 1 && outs[0] == SpeakerArr::kStereo ? kResultTrue : kResultFalse;
    }
    tresult PLUGIN_API getBusArrangement(BusDirection dir, int32 index, SpeakerArrangement& arr) override {
        if (dir != kOutput || index != 0) return kInvalidArgument;
        arr = SpeakerArr::kStereo;
        return kResultOk;
    }
    tresult PLUGIN_API process(ProcessData& data) override {
        takeChanges(data);
        if (data.inputEvents) {
            Event e{};
            for (int32 i = 0; i < data.inputEvents->getEventCount(); ++i) {
                if (data.inputEvents->getEvent(i, e) != kResultOk) continue;
                if (e.type == Event::kNoteOnEvent) {
                    pitch_ = e.noteOn.pitch;
                    level_ = 0.2f * e.noteOn.velocity;
                } else if (e.type == Event::kNoteOffEvent && e.noteOff.pitch == pitch_ && values_[0] < 0.5f) {
                    level_ = 0.0f;  // (held while the pedal is down)
                }
            }
        }
        if (data.numOutputs < 1) return kResultOk;
        const double step = 2.0 * 3.14159265358979 * 440.0 * std::pow(2.0, (pitch_ - 69) / 12.0) / sample_rate_;
        for (int32 i = 0; i < data.numSamples; ++i) {
            const float v = level_ * float(std::sin(phase_));
            phase_ += step;
            for (int32 c = 0; c < data.outputs[0].numChannels; ++c) data.outputs[0].channelBuffers32[c][i] = v;
        }
        return kResultOk;
    }
    tresult PLUGIN_API getParameterInfo(int32 index, ParameterInfo& info) override {
        if (index != 0) return kInvalidArgument;
        info = {};
        info.id = 0;
        copy128(info.title, "Sustain");
        info.stepCount = 1;
        info.flags = ParameterInfo::kCanAutomate;
        return kResultOk;
    }
    tresult PLUGIN_API getParamStringByValue(ParamID, ParamValue value, String128 text) override {
        copy128(text, value >= 0.5 ? "on" : "off");
        return kResultOk;
    }
    tresult PLUGIN_API getMidiControllerAssignment(int32 bus, int16, CtrlNumber cc, ParamID& id) override {
        if (bus != 0 || cc != kCtrlSustainOnOff) return kResultFalse;
        id = 0;
        return kResultTrue;
    }

protected:
    int count() const override { return 1; }

private:
    int pitch_ = 69;
    float level_ = 0.0f;
    double phase_ = 0.0;
};

// A limiter as plain as can be, for the checks of a dynamics plug-in's gain reduction meter: each block, whatever of
// its peak is over Threshold (parameter 0: 0 dBFS down to -48) is taken off the whole block, and how much it took off
// goes out on its read-only meter, Gain Reduction (parameter 1: 0 to 48 dB), which it writes as "-6.0 dB".
class Squash final : public Plugin {
public:
    Squash() { values_[0] = 1.0f; }
    int32 PLUGIN_API getBusCount(MediaType type, BusDirection) override { return type == kAudio ? 1 : 0; }
    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& bus) override {
        if (type != kAudio || index != 0) return kInvalidArgument;
        bus.mediaType = kAudio;
        bus.direction = dir;
        bus.channelCount = SpeakerArr::getChannelCount(arrangement_);
        copy128(bus.name, dir == kInput ? "In" : "Out");
        bus.busType = kMain;
        bus.flags = BusInfo::kDefaultActive;
        return kResultOk;
    }
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement* ins, int32 nin, SpeakerArrangement* outs, int32 nout) override {
        if (nin != 1 || nout != 1 || ins[0] != outs[0] || (ins[0] != SpeakerArr::kMono && ins[0] != SpeakerArr::kStereo)) return kResultFalse;
        arrangement_ = ins[0];
        return kResultTrue;
    }
    tresult PLUGIN_API getBusArrangement(BusDirection, int32 index, SpeakerArrangement& arr) override {
        if (index != 0) return kInvalidArgument;
        arr = arrangement_;
        return kResultOk;
    }
    tresult PLUGIN_API process(ProcessData& data) override {
        takeChanges(data);
        if (data.numInputs < 1 || data.numOutputs < 1) return kResultOk;
        float peak = 0.0f;
        for (int32 c = 0; c < data.inputs[0].numChannels; ++c)
            for (int32 i = 0; i < data.numSamples; ++i) peak = std::max(peak, std::fabs(data.inputs[0].channelBuffers32[c][i]));
        const double threshold = -kSquashRangeDb * (1.0 - values_[0]);
        const double over = peak > 0.0f ? std::max(20.0 * std::log10(double(peak)) - threshold, 0.0) : 0.0;
        const float gain = float(std::pow(10.0, -over / 20.0));
        for (int32 c = 0; c < data.outputs[0].numChannels; ++c) {
            const float* in = data.inputs[0].channelBuffers32[std::min(c, data.inputs[0].numChannels - 1)];
            float* out = data.outputs[0].channelBuffers32[c];
            for (int32 i = 0; i < data.numSamples; ++i) out[i] = in[i] * gain;
        }
        values_[1] = float(std::min(over / kSquashRangeDb, 1.0));
        if (data.outputParameterChanges) {  // (its meter, for the host to show)
            int32 queue = 0, point = 0;
            if (IParamValueQueue* q = data.outputParameterChanges->addParameterData(1, queue)) q->addPoint(0, values_[1], point);
        }
        return kResultOk;
    }
    tresult PLUGIN_API getParameterInfo(int32 index, ParameterInfo& info) override {
        if (index < 0 || index > 1) return kInvalidArgument;
        info = {};
        info.id = ParamID(index);
        copy128(info.title, index == 0 ? "Threshold" : "Gain Reduction");
        copy128(info.shortTitle, index == 0 ? "Thresh" : "GR");
        copy128(info.units, "dB");
        info.defaultNormalizedValue = index == 0 ? 1.0 : 0.0;
        info.flags = index == 0 ? ParameterInfo::kCanAutomate : ParameterInfo::kIsReadOnly;
        return kResultOk;
    }
    tresult PLUGIN_API getParamStringByValue(ParamID id, ParamValue value, String128 text) override {
        if (id > 1) return kInvalidArgument;
        char s[32];
        std::snprintf(s, sizeof(s), "%.1f", id == 0 ? -kSquashRangeDb * (1.0 - value) : -kSquashRangeDb * value);
        copy128(text, s);
        return kResultOk;
    }

protected:
    int count() const override { return 2; }

private:
    SpeakerArrangement arrangement_ = SpeakerArr::kStereo;
};

// (IPluginFactory too, as a base: the SDK's Windows host asks for it by name.)
class Factory final : public U::Implements<U::Directly<IPluginFactory2>, U::Indirectly<IPluginFactory>> {
public:
    tresult PLUGIN_API getFactoryInfo(PFactoryInfo* info) override {
        *info = {};
        std::strcpy(info->vendor, "Studiolator checks");
        info->flags = PFactoryInfo::kUnicode;
        return kResultOk;
    }
    int32 PLUGIN_API countClasses() override { return 5; }
    tresult PLUGIN_API getClassInfo(int32 index, PClassInfo* info) override {
        PClassInfo2 two{};
        if (getClassInfo2(index, &two) != kResultOk) return kInvalidArgument;
        std::memcpy(info->cid, two.cid, sizeof(TUID));
        info->cardinality = two.cardinality;
        std::strcpy(info->category, two.category);
        std::strcpy(info->name, two.name);
        return kResultOk;
    }
    tresult PLUGIN_API getClassInfo2(int32 index, PClassInfo2* info) override {
        if (index < 0 || index > 4) return kInvalidArgument;
        *info = {};
        const FUID* ids[5] = {&kGainId, &kToneId, &kEchoId, &kLookaheadId, &kSquashId};
        const char* names[5] = {"SR Test Gain", "SR Test Tone", "SR Test Echo", "SR Test Lookahead", "SR Test Squash"};
        const char* kinds[5] = {"Fx|Dynamics", "Instrument|Synth", "Fx|Delay", "Fx|Mastering", "Fx|Dynamics"};
        ids[index]->toTUID(info->cid);
        info->cardinality = PClassInfo::kManyInstances;
        std::strcpy(info->category, kVstAudioEffectClass);
        std::strcpy(info->name, names[index]);
        std::strcpy(info->subCategories, kinds[index]);
        std::strcpy(info->vendor, "Studiolator checks");
        std::strcpy(info->version, "1.0.0");
        std::strcpy(info->sdkVersion, kVstVersionString);
        return kResultOk;
    }
    tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void** obj) override {
        FUnknown* made = nullptr;
        if (FUnknownPrivate::iidEqual(cid, kGainId.toTUID())) made = static_cast<IComponent*>(new Gain());
        else if (FUnknownPrivate::iidEqual(cid, kToneId.toTUID())) made = static_cast<IComponent*>(new Tone());
        else if (FUnknownPrivate::iidEqual(cid, kEchoId.toTUID())) made = static_cast<IComponent*>(new Echo());
        else if (FUnknownPrivate::iidEqual(cid, kLookaheadId.toTUID())) made = static_cast<IComponent*>(new Lookahead());
        else if (FUnknownPrivate::iidEqual(cid, kSquashId.toTUID())) made = static_cast<IComponent*>(new Squash());
        if (!made) {
            *obj = nullptr;
            return kNoInterface;
        }
        const tresult found = made->queryInterface(iid, obj);
        made->release();
        return found;
    }
};

}  // namespace

extern "C" {
SMTG_EXPORT_SYMBOL IPluginFactory* PLUGIN_API GetPluginFactory() { return new Factory(); }
#if defined(__APPLE__)
SMTG_EXPORT_SYMBOL bool bundleEntry(CFBundleRef) { return true; }
SMTG_EXPORT_SYMBOL bool bundleExit() { return true; }
#elif defined(_WIN32)
SMTG_EXPORT_SYMBOL bool InitDll() { return true; }
SMTG_EXPORT_SYMBOL bool ExitDll() { return true; }
#else
SMTG_EXPORT_SYMBOL bool ModuleEntry(void*) { return true; }
SMTG_EXPORT_SYMBOL bool ModuleExit() { return true; }
#endif
}
