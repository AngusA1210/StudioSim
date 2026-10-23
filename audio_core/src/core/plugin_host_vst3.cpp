// VST3 hosting, with Steinberg's VST 3 SDK (MIT-licensed): the plug-ins in the system's VST3 folders, loaded into the
// game's process and played one channel at a time (two on a bus), with their own windows floating over the game.
//
// A plug-in is found by reading its bundle's moduleinfo.json, which describes it without loading it; one that has none
// is loaded once to ask it, and remembered until its bundle changes. Its id is "VST3:" and its class id as the SDK
// writes it on every platform, so the same plug-in has the same id on macOS and Windows.
//
// Its controls are its parameters, normalized (0 to 1), as VST3 has them: set from the automation (the audio thread)
// or from its own window, each goes to it at the start of the next block. Its settings are its processor's state and
// its controller's, together. An instrument is played by notes (as events) and its controllers (as the parameters it
// maps them to).

#include "file_util.h"
#include "plugin_formats.h"
#include "plugin_window.h"

#include <array>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <unordered_map>

#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/gui/iplugviewcontentscalesupport.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivstunits.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/eventlist.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
#include "public.sdk/source/vst/hosting/processdata.h"
#include "public.sdk/source/vst/moduleinfo/moduleinfoparser.h"
#include "public.sdk/source/vst/utility/stringconvert.h"

namespace sr {
namespace {

using namespace Steinberg;
using namespace Steinberg::Vst;
namespace Hosting = VST3::Hosting;

// ── Finding them ────────────────────────────────────────────────────────────────────────────────────────────

class Host final : public HostApplication {
public:
    tresult PLUGIN_API getName(String128 name) override { return StringConvert::convert("SoundRoom", name) ? kResultTrue : kInternalError; }
};

Host& host() {
    static Host* the_host = new Host();  // (for as long as any plug-in may hold it)
    return *the_host;
}

struct Found {
    std::string path;  // its module's
    PluginDescription description;
};
struct Scanned {
    std::filesystem::file_time_type when;
    std::vector<Found> classes;
    std::string problem;  // why it wouldn't load, if it wouldn't
};

std::mutex g_lock;                                 // what follows (the game thread's, but the checks run anywhere)
std::vector<std::string> g_search;                 // where to look, if not the system's folders
bool g_search_set = false;
std::map<std::string, Scanned> g_scanned;          // each module found, by its path
std::map<std::string, Hosting::Module::Ptr> g_loaded;  // each module loaded (kept for as long as SoundRoom runs)

bool isBundle(const std::filesystem::path& p) {
    std::string ext = p.extension().string();
    for (char& c : ext) c = char(std::tolower(static_cast<unsigned char>(c)));
    return ext == ".vst3";
}

// Every .vst3 under `folder` (in makers' folders too, but not inside another plug-in's bundle).
void collect(const std::filesystem::path& folder, std::vector<std::string>& out, int depth = 0) {
    std::error_code ec;
    if (depth > 4 || !std::filesystem::is_directory(folder, ec)) return;
    for (const auto& entry : std::filesystem::directory_iterator(folder, ec)) {
        if (isBundle(entry.path())) out.push_back(entry.path().u8string());
        else if (entry.is_directory(ec)) collect(entry.path(), out, depth + 1);
    }
}

std::vector<std::string> modulePaths() {
    if (!g_search_set) return Hosting::Module::getModulePaths();
    std::vector<std::string> out;
    for (const std::string& p : g_search) {
        if (isBundle(pathOf(p))) out.push_back(p);
        else collect(pathOf(p), out);
    }
    return out;
}

Hosting::Module::Ptr loadModule(const std::string& path, std::string* error) {
    auto it = g_loaded.find(path);
    if (it != g_loaded.end()) return it->second;
    std::string problem;
    auto module = Hosting::Module::create(path, problem);
    if (!module) {
        if (error) *error = problem.empty() ? "its module wouldn't load" : problem;
        return nullptr;
    }
    module->getFactory().setHostContext(&host());
    g_loaded[path] = module;
    return module;
}

void addClass(std::vector<Found>& out, const std::string& path, const std::string& cid, const std::string& category,
              const std::string& name, const std::string& vendor, const std::vector<std::string>& subcategories) {
    if (category != kVstAudioEffectClass) return;  // (its controller, or something else it makes)
    auto uid = VST3::UID::fromString(cid);
    if (!uid) return;
    Found f;
    f.path = path;
    f.description.id = "VST3:" + uid->toString();
    f.description.format = "VST3";
    f.description.name = name;
    f.description.maker = vendor;
    for (const std::string& s : subcategories)
        if (s == "Instrument") f.description.instrument = true;
    f.description.category = vst3Category(subcategories, f.description.instrument);  // (what it says it is, if it does)
    if (f.description.category.empty())
        f.description.category = f.description.instrument ? guessInstrumentCategory(name, vendor, subcategories)
                                                           : guessPluginCategory(name, vendor, subcategories);
    out.push_back(std::move(f));
}

// What a module holds: from its moduleinfo.json if it has one, or by loading it and asking its factory.
std::vector<Found> scanModule(const std::string& path, std::string* problem) {
    std::vector<Found> out;
    if (auto info_path = Hosting::Module::getModuleInfoPath(path)) {
        std::ifstream file(pathOf(*info_path), std::ios::binary);
        std::stringstream json;
        json << file.rdbuf();
        if (auto info = ModuleInfoLib::parseJson(json.str(), nullptr)) {
            for (const auto& c : info->classes)
                addClass(out, path, c.cid, c.category, c.name, c.vendor.empty() ? info->factoryInfo.vendor : c.vendor, c.subCategories);
            return out;
        }
    }
    auto module = loadModule(path, problem);
    if (!module) return out;
    const auto factory_vendor = module->getFactory().info().vendor();
    const auto classes = module->getFactory().classInfos();
    for (const auto& c : classes)
        addClass(out, path, c.ID().toString(), c.category(), c.name(), c.vendor().empty() ? factory_vendor : c.vendor(), c.subCategories());
    if (out.empty() && problem) *problem = "none of the " + std::to_string(classes.size()) + " things it makes is an audio plug-in";
    return out;
}

// Every plug-in class found, looking again at modules that are new or changed (with the lock held).
std::vector<Found> everything() {
    std::vector<Found> out;
    std::map<std::string, Scanned> seen;
    for (const std::string& path : modulePaths()) {
        std::error_code ec;
        const auto when = std::filesystem::last_write_time(pathOf(path), ec);
        auto it = g_scanned.find(path);
        Scanned scanned;
        if (it != g_scanned.end() && it->second.when == when) {
            scanned = it->second;
        } else {
            scanned.when = when;
            scanned.classes = scanModule(path, &scanned.problem);
        }
        out.insert(out.end(), scanned.classes.begin(), scanned.classes.end());
        seen[path] = std::move(scanned);
    }
    g_scanned = std::move(seen);
    return out;
}

std::string utf8(const String128 s) { return StringConvert::convert(s); }

// ── Talking to the host: edits made in its window, its requests to resize it ─────────────────────────────────

class Vst3Plugin;

class Handler final : public U::ImplementsNonDestroyable<U::Directly<IComponentHandler>> {
public:
    explicit Handler(Vst3Plugin* owner) : owner_(owner) {}
    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override;
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32 flags) override;

private:
    Vst3Plugin* owner_;
};

class Frame final : public U::ImplementsNonDestroyable<U::Directly<IPlugFrame>> {
public:
    explicit Frame(Vst3Plugin* owner) : owner_(owner) {}
    tresult PLUGIN_API resizeView(IPlugView* view, ViewRect* size) override;

private:
    Vst3Plugin* owner_;
};

// ── A plug-in ─────────────────────────────────────────────────────────────────────────────────────────────────

constexpr char kStateMagic[4] = {'S', 'R', 'V', '3'};

class Vst3Plugin final : public PluginInstance {
public:
    Vst3Plugin(Hosting::Module::Ptr module, IPtr<IComponent> component, IPtr<IEditController> controller, PluginDescription description)
        : module_(std::move(module)), component_(std::move(component)), controller_(std::move(controller)),
          description_(std::move(description)), handler_(this), frame_(this) {
        processor_ = U::cast<IAudioProcessor>(component_);
        single_ = controller_ && U::cast<IEditController>(component_).get() == controller_.get();
        if (controller_) {
            controller_->setComponentHandler(&handler_);
            if (!single_) {  // the processor and its controller, told of each other, and the controller of its state
                cp_component_ = U::cast<IConnectionPoint>(component_);
                cp_controller_ = U::cast<IConnectionPoint>(controller_);
                if (cp_component_ && cp_controller_) {
                    cp_component_->connect(cp_controller_);
                    cp_controller_->connect(cp_component_);
                }
                MemoryStream state;
                if (component_->getState(&state) == kResultOk) {
                    state.seek(0, IBStream::kIBSeekSet, nullptr);
                    controller_->setComponentState(&state);
                }
            }
            const int32 count = controller_->getParameterCount();
            for (int32 i = 0; i < count; ++i) {
                ParameterInfo info{};
                if (controller_->getParameterInfo(i, info) != kResultOk) continue;
                index_[info.id] = int(ids_.size());
                ids_.push_back(info.id);
                infos_.push_back(info);
            }
        }
        values_ = std::make_unique<std::atomic<float>[]>(ids_.size() + 1);
        dirty_ = std::make_unique<std::atomic<bool>[]>(ids_.size() + 1);
        for (size_t i = 0; i < ids_.size(); ++i) {
            values_[i].store(controller_ ? float(controller_->getParamNormalized(ids_[i])) : 0.0f);
            dirty_[i].store(false);
        }
        changes_ = std::make_unique<ParameterChanges>(int32(ids_.size()) + kMaxMapped);
        out_changes_ = std::make_unique<ParameterChanges>(int32(ids_.size()) + 1);  // (what it says back: its meters)
        for (const ParameterInfo& info : infos_)  // its gain reduction meters, if it has any
            if ((info.flags & ParameterInfo::kIsReadOnly) && reduction_count_ < kMaxReduction && isGainReductionName(utf8(info.title))) {
                reduction_ids_[size_t(reduction_count_)] = info.id;
                reduction_[size_t(reduction_count_++)].store(-1.0f);
            }
        events_.setMaxSize(512);
    }

    ~Vst3Plugin() override {
        if (view_) {
            view_->removed();
            view_->setFrame(nullptr);
            view_ = nullptr;
        }
        window_.reset();
        stop();
        if (cp_component_ && cp_controller_) {
            cp_component_->disconnect(cp_controller_);
            cp_controller_->disconnect(cp_component_);
        }
        if (controller_) {
            controller_->setComponentHandler(nullptr);
            if (!single_) controller_->terminate();
        }
        data_.unprepare();
        component_->terminate();
    }

    const PluginDescription& description() const override { return description_; }
    bool isInstrument() const override { return description_.instrument; }

    bool prepare(double sample_rate, int max_frames, std::string* error, bool stereo = false) override {
        stop();
        if (!processor_) {
            if (error) *error = "it doesn't process audio";
            return false;
        }
        sample_rate_ = sample_rate;
        ProcessSetup setup{kRealtime, kSample32, max_frames, sample_rate};
        if (processor_->setupProcessing(setup) != kResultOk) {
            if (error) *error = "it wouldn't start at this sample rate";
            return false;
        }
        // Its main buses as one channel or two, as it will take them (an instrument: out only); any others (side-
        // chains, more outputs) switched off. An effect on a pedal or a track takes one channel if it will; on a bus,
        // two first.
        const int32 ins = component_->getBusCount(kAudio, kInput), outs = component_->getBusCount(kAudio, kOutput);
        std::vector<SpeakerArrangement> in_arr(size_t(std::max(ins, 1)), SpeakerArr::kStereo), out_arr(size_t(std::max(outs, 1)), SpeakerArr::kStereo);
        for (int32 b = 0; b < ins; ++b) processor_->getBusArrangement(kInput, b, in_arr[size_t(b)]);
        for (int32 b = 0; b < outs; ++b) processor_->getBusArrangement(kOutput, b, out_arr[size_t(b)]);
        const SpeakerArrangement mono = SpeakerArr::kMono, two = SpeakerArr::kStereo;
        const SpeakerArrangement mono_first[3][2] = {{mono, mono}, {two, two}, {mono, two}}, stereo_first[3][2] = {{two, two}, {mono, two}, {mono, mono}};
        const SpeakerArrangement instrument_first[2][2] = {{two, two}, {mono, mono}};
        const SpeakerArrangement(*layouts)[2] = description_.instrument ? instrument_first : (stereo ? stereo_first : mono_first);
        const int tries = description_.instrument ? 2 : 3;
        for (int t = 0; t < tries; ++t) {
            if (ins > 0) in_arr[0] = layouts[t][0];
            if (outs > 0) out_arr[0] = layouts[t][1];
            if (processor_->setBusArrangements(ins > 0 ? in_arr.data() : nullptr, ins, outs > 0 ? out_arr.data() : nullptr, outs) == kResultTrue) break;
        }
        // Whatever it settled on.
        in_channels_ = out_channels_ = 0;
        if (ins > 0 && processor_->getBusArrangement(kInput, 0, in_arr[0]) == kResultOk) in_channels_ = SpeakerArr::getChannelCount(in_arr[0]);
        if (outs > 0 && processor_->getBusArrangement(kOutput, 0, out_arr[0]) == kResultOk) out_channels_ = SpeakerArr::getChannelCount(out_arr[0]);
        if (out_channels_ == 0) {
            if (error) *error = "it has no audio output";
            return false;
        }
        for (int32 b = 0; b < ins; ++b) component_->activateBus(kAudio, kInput, b, b == 0);
        for (int32 b = 0; b < outs; ++b) component_->activateBus(kAudio, kOutput, b, b == 0);
        if (component_->getBusCount(kEvent, kInput) > 0) component_->activateBus(kEvent, kInput, 0, description_.instrument);
        if (!data_.prepare(*component_, max_frames, kSample32)) {
            if (error) *error = "its buffers couldn't be made";
            return false;
        }
        data_.inputParameterChanges = changes_.get();
        data_.outputParameterChanges = out_changes_.get();
        data_.inputEvents = description_.instrument ? &events_ : nullptr;
        data_.processContext = &context_;
        if (component_->setActive(true) != kResultOk) {
            if (error) *error = "it wouldn't start";
            return false;
        }
        active_ = true;
        processor_->setProcessing(true);  // (many don't need telling, and say so)
        latency_ = int(processor_->getLatencySamples());
        max_frames_ = max_frames;
        mapMidi();
        return true;
    }

    void process(float* io, int n) override {
        if (!active_ || n > max_frames_ || description_.instrument) return;
        feed(io, io, n);
        run(n);
        const float* a = output(0);
        const float* b = out_channels_ > 1 ? output(1) : a;
        if (!a) return;
        for (int i = 0; i < n; ++i) io[i] = out_channels_ > 1 ? 0.5f * (a[i] + b[i]) : a[i];
    }

    void processStereo(float* left, float* right, int n) override {
        if (!active_ || n > max_frames_ || description_.instrument) return;
        if (in_channels_ < 2 && out_channels_ < 2) {  // a one-channel plug-in: the two together, played in both
            PluginInstance::processStereo(left, right, n);
            return;
        }
        feed(left, right, n);
        run(n);
        const float* a = output(0);
        const float* b = out_channels_ > 1 ? output(1) : a;
        if (!a) return;
        std::copy(a, a + n, left);
        std::copy(b, b + n, right);
    }

    void midi(uint8_t status, uint8_t data1, uint8_t data2, int offset) override {
        if (!active_ || !description_.instrument) return;
        const uint8_t type = status & 0xF0;
        const int16 channel = int16(status & 0x0F);
        Event e{};
        e.busIndex = 0;
        e.sampleOffset = std::max(offset, 0);
        e.flags = Event::kIsLive;
        if (type == 0x90 && data2 > 0) {
            e.type = Event::kNoteOnEvent;
            e.noteOn = {channel, int16(data1), 0.0f, float(data2) / 127.0f, 0, -1};
            events_.addEvent(e);
        } else if (type == 0x80 || type == 0x90) {
            e.type = Event::kNoteOffEvent;
            e.noteOff = {channel, int16(data1), float(data2) / 127.0f, -1, 0.0f};
            events_.addEvent(e);
        } else if (type == 0xA0) {
            e.type = Event::kPolyPressureEvent;
            e.polyPressure = {channel, int16(data1), float(data2) / 127.0f, -1};
            events_.addEvent(e);
        } else if (type == 0xB0) {  // a controller (the sustain pedal among them): the parameter it is mapped to
            mapped(cc_[data1 & 0x7F], e.sampleOffset, float(data2) / 127.0f);
        } else if (type == 0xD0) {
            mapped(aftertouch_, e.sampleOffset, float(data1) / 127.0f);
        } else if (type == 0xE0) {
            mapped(bend_, e.sampleOffset, float((data2 << 7) | data1) / 16383.0f);
        }
    }

    void render(float* out, int n) override {
        if (!active_ || n > max_frames_ || !description_.instrument) return;
        for (int c = 0; c < in_channels_; ++c)
            if (float* in = input(c)) std::fill(in, in + n, 0.0f);
        run(n);
        const float* a = output(0);
        const float* b = out_channels_ > 1 ? output(1) : a;
        if (!a) return;
        for (int i = 0; i < n; ++i) out[i] += out_channels_ > 1 ? 0.5f * (a[i] + b[i]) : a[i];
    }

    void setTempo(double bpm) override { tempo_.store(bpm, std::memory_order_relaxed); }
    int latencySamples() const override { return latency_; }

    // ── Its window ──
    bool showEditor(const std::string& title) override {
        if (!view_) {
            if (!controller_) return false;
            IPtr<IPlugView> view = owned(controller_->createView(ViewType::kEditor));
            const char* type = PluginWindow::platformType();
            if (!view || !*type || view->isPlatformTypeSupported(type) != kResultTrue) return false;
            ViewRect size{};
            view->getSize(&size);
            window_ = PluginWindow::make(size.getWidth(), size.getHeight());
            if (!window_) return false;
            view->setFrame(&frame_);
#if defined(_WIN32)
            if (auto scaling = U::cast<IPlugViewContentScaleSupport>(view)) scaling->setContentScaleFactor(float(window_->scale()));
#endif
            view_ = view;  // (before it is attached: some ask for another size while they are being attached)
            if (view->attached(window_->nativeView(), type) != kResultOk) {
                view->setFrame(nullptr);
                view_ = nullptr;
                window_.reset();
                return false;
            }
            if (view_->getSize(&size) == kResultOk) window_->setContentSize(size.getWidth(), size.getHeight());
        }
        window_->show(title);
        return true;
    }

    void hideEditor() override {
        if (window_) window_->hide();
    }
    bool editorVisible() const override { return window_ && window_->visible(); }
    void placeEditor(double above_bottom) override {
        if (window_) window_->place(above_bottom);
    }

    // The plug-in asks for another size (from its own size menu, or as it is dragged).
    tresult resized(IPlugView* view, ViewRect* size) {
        if (!view || !size || view != view_.get() || !window_) return kInvalidArgument;
        window_->setContentSize(size->getWidth(), size->getHeight());
        view->onSize(size);
        return kResultTrue;
    }

    // ── Its settings ──
    std::vector<uint8_t> saveState() const override {
        MemoryStream comp, ctrl;
        if (component_->getState(&comp) != kResultOk) return {};
        if (controller_ && !single_) controller_->getState(&ctrl);
        std::vector<uint8_t> out(kStateMagic, kStateMagic + 4);
        const std::string cid = description_.id.substr(5);
        out.insert(out.end(), cid.begin(), cid.end());
        auto put = [&](MemoryStream& s) {
            const uint64_t size = uint64_t(s.getSize());
            for (int i = 0; i < 8; ++i) out.push_back(uint8_t(size >> (8 * i)));
            const auto* bytes = reinterpret_cast<const uint8_t*>(s.getData());
            out.insert(out.end(), bytes, bytes + size);
        };
        put(comp);
        put(ctrl);
        return out;
    }

    bool loadState(const std::vector<uint8_t>& state) override {
        std::vector<uint8_t> comp, ctrl;
        if (!unpackState(state, nullptr, &comp, &ctrl)) return false;
        MemoryStream comp_stream(comp.data(), TSize(comp.size()));
        if (component_->setState(&comp_stream) != kResultOk) return false;
        if (controller_) {
            comp_stream.seek(0, IBStream::kIBSeekSet, nullptr);
            controller_->setComponentState(&comp_stream);
            if (!ctrl.empty() && !single_) {
                MemoryStream ctrl_stream(ctrl.data(), TSize(ctrl.size()));
                controller_->setState(&ctrl_stream);
            }
        }
        refreshValues();
        return true;
    }

    // ── Its controls ──
    std::vector<PluginParameter> parameters() const override {
        std::vector<PluginParameter> out;
        for (const ParameterInfo& info : infos_) {
            if ((info.flags & ParameterInfo::kIsReadOnly) || (info.flags & ParameterInfo::kIsHidden) ||
                (info.flags & ParameterInfo::kIsProgramChange) || (info.flags & ParameterInfo::kIsBypass) || !(info.flags & ParameterInfo::kCanAutomate))
                continue;
            PluginParameter p;
            p.id = info.id;
            p.name = utf8(info.title);
            p.unit = utf8(info.units);
            p.min = 0.0f;
            p.max = 1.0f;
            p.initial = float(info.defaultNormalizedValue);
            if (!p.name.empty()) out.push_back(p);
        }
        return out;
    }

    float parameter(uint32_t id) const override {
        auto it = index_.find(id);
        return it == index_.end() ? 0.0f : values_[size_t(it->second)].load(std::memory_order_relaxed);
    }

    void setParameter(uint32_t id, float value) override {
        auto it = index_.find(id);
        if (it == index_.end()) return;
        values_[size_t(it->second)].store(std::clamp(value, 0.0f, 1.0f), std::memory_order_relaxed);
        dirty_[size_t(it->second)].store(true, std::memory_order_release);
        any_dirty_.store(true, std::memory_order_release);
    }

    void notifyParameter(uint32_t id) override {
        if (controller_) controller_->setParamNormalized(id, parameter(id));
    }

    std::string parameterText(uint32_t id, float value) const override {
        if (!controller_) return "";
        String128 text{};
        if (controller_->getParamStringByValue(id, value, text) != kResultOk) return "";
        auto it = index_.find(id);
        std::string out = utf8(text);
        const std::string unit = it != index_.end() ? utf8(infos_[size_t(it->second)].units) : "";
        return unit.empty() ? out : out + " " + unit;
    }

    // An edit in its own window, for the processor (at the next block) and anything watching its controls.
    void edited(ParamID id, ParamValue value) {
        auto it = index_.find(id);
        if (it == index_.end()) return;
        values_[size_t(it->second)].store(float(value), std::memory_order_relaxed);
        dirty_[size_t(it->second)].store(true, std::memory_order_release);
        any_dirty_.store(true, std::memory_order_release);
    }

    void restart(int32 flags) {
        if (flags & (kParamValuesChanged | kParamTitlesChanged)) refreshValues();
        if ((flags & kLatencyChanged) && processor_) latency_ = int(processor_->getLatencySamples());
    }

    // ── The presets it comes with: its first program list ──
    std::vector<std::string> factoryPresets() const override {
        std::vector<std::string> out;
        auto units = controller_ ? U::cast<IUnitInfo>(controller_) : nullptr;
        ProgramListInfo list{};
        if (!units || units->getProgramListCount() < 1 || units->getProgramListInfo(0, list) != kResultOk) return out;
        for (int32 i = 0; i < list.programCount; ++i) {
            String128 name{};
            out.push_back(units->getProgramName(list.id, i, name) == kResultOk ? utf8(name) : "Program " + std::to_string(i + 1));
        }
        return out;
    }

    bool loadFactoryPreset(int index) override {
        const int count = int(factoryPresets().size());
        for (const ParameterInfo& info : infos_) {  // the program-change parameter, set to it
            if (!(info.flags & ParameterInfo::kIsProgramChange) || count < 1) continue;
            const float value = count > 1 ? float(std::clamp(index, 0, count - 1)) / float(count - 1) : 0.0f;
            setParameter(info.id, value);
            if (controller_) controller_->setParamNormalized(info.id, value);
            return true;
        }
        return false;
    }

    static bool unpackState(const std::vector<uint8_t>& state, std::string* cid, std::vector<uint8_t>* comp, std::vector<uint8_t>* ctrl) {
        if (state.size() < 4 + 32 + 16 || std::memcmp(state.data(), kStateMagic, 4) != 0) return false;
        if (cid) cid->assign(reinterpret_cast<const char*>(state.data()) + 4, 32);
        size_t at = 36;
        auto take = [&](std::vector<uint8_t>* into) {
            if (at + 8 > state.size()) return false;
            uint64_t size = 0;
            for (int i = 0; i < 8; ++i) size |= uint64_t(state[at + size_t(i)]) << (8 * i);
            at += 8;
            if (size > state.size() - at) return false;
            if (into) into->assign(state.begin() + std::ptrdiff_t(at), state.begin() + std::ptrdiff_t(at + size));
            at += size_t(size);
            return true;
        };
        return take(comp) && take(ctrl);
    }

private:
    static constexpr int kMaxMapped = 64;  // controller moves (the pedal, the bend) waiting for a block

    void stop() {
        if (!active_) return;
        if (processor_) processor_->setProcessing(false);
        component_->setActive(false);
        active_ = false;
    }

    float* input(int channel) {
        if (data_.numInputs < 1 || channel >= data_.inputs[0].numChannels) return nullptr;
        return data_.inputs[0].channelBuffers32[channel];
    }
    const float* output(int channel) {
        if (data_.numOutputs < 1 || channel >= data_.outputs[0].numChannels) return nullptr;
        return data_.outputs[0].channelBuffers32[channel];
    }

    // What it hears: one channel in all of its first bus's, or a bus's two (its others silent).
    void feed(const float* left, const float* right, int n) {
        for (int c = 0; c < in_channels_; ++c)
            if (float* in = input(c)) {
                const float* from = c == 0 ? left : (c == 1 ? right : nullptr);
                if (from) std::copy(from, from + n, in);
                else std::fill(in, in + n, 0.0f);
            }
        for (int32 b = 1; b < data_.numInputs; ++b)
            for (int32 c = 0; c < data_.inputs[b].numChannels; ++c) std::fill(data_.inputs[b].channelBuffers32[c], data_.inputs[b].channelBuffers32[c] + n, 0.0f);
    }

    // A block: the parameters changed since the last one (at its start), the controllers moved, where the music is.
    void run(int n) {
        data_.numSamples = n;
        changes_->clearQueue();
        if (any_dirty_.exchange(false, std::memory_order_acq_rel)) {
            for (size_t i = 0; i < ids_.size(); ++i) {
                if (!dirty_[i].exchange(false, std::memory_order_acq_rel)) continue;
                int32 queue = 0, point = 0;
                if (IParamValueQueue* q = changes_->addParameterData(ids_[i], queue))
                    q->addPoint(0, values_[i].load(std::memory_order_relaxed), point);
            }
        }
        for (int m = 0; m < mapped_count_; ++m) {
            int32 queue = 0, point = 0;
            if (IParamValueQueue* q = changes_->addParameterData(mapped_[m].id, queue)) q->addPoint(mapped_[m].offset, mapped_[m].value, point);
        }
        mapped_count_ = 0;
        const double bpm = tempo_.load(std::memory_order_relaxed);
        context_ = {};
        context_.state = ProcessContext::kPlaying | ProcessContext::kTempoValid | ProcessContext::kProjectTimeMusicValid;
        context_.sampleRate = sample_rate_;
        context_.projectTimeSamples = position_;
        context_.tempo = bpm;
        context_.projectTimeMusic = double(position_) / (sample_rate_ * 60.0 / bpm);
        out_changes_->clearQueue();
        processor_->process(data_);
        events_.clear();
        position_ += n;
        for (int32 i = 0; reduction_count_ > 0 && i < out_changes_->getParameterCount(); ++i) {  // (its gain reduction, as it last said)
            IParamValueQueue* q = out_changes_->getParameterData(i);
            int32 offset = 0;
            ParamValue value = 0.0;
            if (!q || q->getPointCount() <= 0 || q->getPoint(q->getPointCount() - 1, offset, value) != kResultOk) continue;
            for (int r = 0; r < reduction_count_; ++r)
                if (q->getParameterId() == reduction_ids_[size_t(r)]) reduction_[size_t(r)].store(float(value), std::memory_order_relaxed);
        }
    }

    // Its gain reduction, in dB, as its own text for the value its meter last said has it ("-4.5 dB", "4.5").
    float gainReductionDb() const override {
        float most = -1.0f;
        for (int r = 0; r < reduction_count_; ++r) {
            const float value = reduction_[size_t(r)].load(std::memory_order_relaxed);
            if (value < 0.0f) continue;
            const std::string text = parameterText(reduction_ids_[size_t(r)], value);
            const size_t at = text.find_first_of("+-.0123456789");
            if (at == std::string::npos) continue;
            most = std::max(most, std::fabs(std::strtof(text.c_str() + at, nullptr)));
        }
        return most;
    }

    void mapped(ParamID id, int32 offset, float value) {
        if (id == kNoParamId || mapped_count_ >= kMaxMapped) return;
        mapped_[mapped_count_++] = {id, offset, value};
    }

    // Which parameter each MIDI controller moves, as the plug-in maps them (the sustain pedal, the bend).
    void mapMidi() {
        std::fill(std::begin(cc_), std::end(cc_), kNoParamId);
        aftertouch_ = bend_ = kNoParamId;
        auto mapping = controller_ ? U::cast<IMidiMapping>(controller_) : nullptr;
        if (!mapping) return;
        for (int16 cc = 0; cc < 128; ++cc) mapping->getMidiControllerAssignment(0, 0, CtrlNumber(cc), cc_[cc]);
        mapping->getMidiControllerAssignment(0, 0, kAfterTouch, aftertouch_);
        mapping->getMidiControllerAssignment(0, 0, kPitchBend, bend_);
    }

    void refreshValues() {
        if (!controller_) return;
        for (size_t i = 0; i < ids_.size(); ++i) values_[i].store(float(controller_->getParamNormalized(ids_[i])), std::memory_order_relaxed);
    }

    Hosting::Module::Ptr module_;
    IPtr<IComponent> component_;
    IPtr<IAudioProcessor> processor_;
    IPtr<IEditController> controller_;
    IPtr<IConnectionPoint> cp_component_, cp_controller_;
    bool single_ = false;
    PluginDescription description_;
    Handler handler_;
    Frame frame_;
    HostProcessData data_;
    std::unique_ptr<ParameterChanges> changes_, out_changes_;
    static constexpr int kMaxReduction = 4;
    std::array<ParamID, kMaxReduction> reduction_ids_{};
    std::array<std::atomic<float>, kMaxReduction> reduction_{};  // (normalized; -1: not said yet)
    int reduction_count_ = 0;
    EventList events_;
    ProcessContext context_{};
    std::vector<ParamID> ids_;
    std::vector<ParameterInfo> infos_;
    std::unordered_map<ParamID, int> index_;
    std::unique_ptr<std::atomic<float>[]> values_;
    std::unique_ptr<std::atomic<bool>[]> dirty_;
    std::atomic<bool> any_dirty_{false};
    struct Mapped {
        ParamID id;
        int32 offset;
        float value;
    };
    Mapped mapped_[kMaxMapped];
    int mapped_count_ = 0;
    ParamID cc_[128];
    ParamID aftertouch_ = kNoParamId, bend_ = kNoParamId;
    bool active_ = false;
    int in_channels_ = 0, out_channels_ = 0, max_frames_ = 0, latency_ = 0;
    double sample_rate_ = 48000.0;
    int64 position_ = 0;
    std::atomic<double> tempo_{120.0};
    IPtr<IPlugView> view_;
    std::unique_ptr<PluginWindow> window_;
};

tresult PLUGIN_API Handler::performEdit(ParamID id, ParamValue value) {
    owner_->edited(id, value);
    return kResultOk;
}
tresult PLUGIN_API Handler::restartComponent(int32 flags) {
    owner_->restart(flags);
    return kResultOk;
}
tresult PLUGIN_API Frame::resizeView(IPlugView* view, ViewRect* size) { return owner_->resized(view, size); }

// ── Preset files (.vstpreset, as every VST3 host writes them) ─────────────────────────────────────────────────

void putInt(std::string& out, uint64_t v, int bytes) {
    for (int i = 0; i < bytes; ++i) out.push_back(char(uint8_t(v >> (8 * i))));
}
uint64_t getInt(const std::string& in, size_t at, int bytes) {
    uint64_t v = 0;
    for (int i = 0; i < bytes && at + size_t(i) < in.size(); ++i) v |= uint64_t(uint8_t(in[at + size_t(i)])) << (8 * i);
    return v;
}

}  // namespace

// ── The format's own entry points ──────────────────────────────────────────────────────────────────────────

void setVst3SearchPaths(const std::vector<std::string>& paths) {
    std::lock_guard<std::mutex> lock(g_lock);
    g_search = paths;
    g_search_set = !paths.empty();
    g_scanned.clear();
}

std::vector<std::string> vst3ScanProblems() {
    std::lock_guard<std::mutex> lock(g_lock);
    std::vector<std::string> out;
    for (const auto& [path, scanned] : g_scanned)
        if (!scanned.problem.empty()) out.push_back(path + ": " + scanned.problem);
    return out;
}

std::vector<PluginDescription> vst3Plugins(bool instruments) {
    std::lock_guard<std::mutex> lock(g_lock);
    std::vector<PluginDescription> out;
    for (const Found& f : everything())
        if (f.description.instrument == instruments) out.push_back(f.description);
    std::sort(out.begin(), out.end(), [](const PluginDescription& a, const PluginDescription& b) { return a.id < b.id; });
    out.erase(std::unique(out.begin(), out.end(), [](const PluginDescription& a, const PluginDescription& b) { return a.id == b.id; }), out.end());
    return out;
}

std::unique_ptr<PluginInstance> vst3Load(const std::string& id, std::string* error) {
    std::lock_guard<std::mutex> lock(g_lock);
    const std::string cid = id.size() > 5 ? id.substr(5) : "";
    auto uid = VST3::UID::fromString(cid);
    if (!uid) {
        if (error) *error = "\"" + id + "\" isn't a plug-in";
        return nullptr;
    }
    const Found* found = nullptr;
    std::vector<Found> all;
    for (const auto& [path, scanned] : g_scanned)
        for (const Found& f : scanned.classes)
            if (f.description.id == id) found = &f;
    if (!found) {  // (not looked for yet, or installed since)
        all = everything();
        for (const Found& f : all)
            if (f.description.id == id) found = &f;
    }
    if (!found) {
        if (error) *error = "it isn't installed";
        return nullptr;
    }
    auto module = loadModule(found->path, error);
    if (!module) return nullptr;
    const auto& factory = module->getFactory();
    IPtr<IComponent> component = factory.createInstance<IComponent>(*uid);
    if (!component || component->initialize(&host()) != kResultOk) {
        if (error) *error = "it wouldn't load";
        return nullptr;
    }
    IPtr<IEditController> controller = U::cast<IEditController>(component);
    if (!controller) {
        TUID controller_id{};
        if (component->getControllerClassId(controller_id) == kResultOk) {
            controller = factory.createInstance<IEditController>(VST3::UID::fromTUID(controller_id));
            if (controller && controller->initialize(&host()) != kResultOk) controller = nullptr;
        }
    }
    return std::make_unique<Vst3Plugin>(module, component, controller, found->description);
}

// A .vstpreset: 'VST3', its version, the plug-in's class id (32 characters), where its list of chunks is; the chunks
// (the processor's state, 'Comp', and the controller's, 'Cont'); then that list: 'List', how many, and each one's id,
// where it starts and how long it is.
bool vst3WritePreset(const std::string& path, const std::string& name, const std::vector<uint8_t>& state, std::string* error) {
    std::string cid;
    std::vector<uint8_t> comp, ctrl;
    if (!Vst3Plugin::unpackState(state, &cid, &comp, &ctrl)) {
        if (error) *error = "there are no settings to save";
        return false;
    }
    std::string out = "VST3";
    putInt(out, 1, 4);
    out += cid;
    const size_t list_at = out.size();
    putInt(out, 0, 8);  // (where the list is: filled in below)
    struct Chunk {
        const char* id;
        size_t offset, size;
    };
    std::vector<Chunk> chunks;
    chunks.push_back({"Comp", out.size(), comp.size()});
    out.append(comp.begin(), comp.end());
    if (!ctrl.empty()) {
        chunks.push_back({"Cont", out.size(), ctrl.size()});
        out.append(ctrl.begin(), ctrl.end());
    }
    const std::string meta = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<MetaInfo>\n\t<Attr id=\"MediaType\" value=\"VstPreset\" type=\"string\" flags=\"writeProtected\"></Attr>\n\t<Attr id=\"Name\" value=\"" +
                             name + "\" type=\"string\" flags=\"\"></Attr>\n</MetaInfo>\n";
    chunks.push_back({"Info", out.size(), meta.size()});
    out += meta;
    const uint64_t list = out.size();
    for (int i = 0; i < 8; ++i) out[list_at + size_t(i)] = char(uint8_t(list >> (8 * i)));
    out += "List";
    putInt(out, chunks.size(), 4);
    for (const Chunk& c : chunks) {
        out.append(c.id, 4);
        putInt(out, c.offset, 8);
        putInt(out, c.size, 8);
    }
    std::error_code ec;
    std::filesystem::create_directories(pathOf(path).parent_path(), ec);
    std::ofstream file(pathOf(path), std::ios::binary | std::ios::trunc);
    if (!file || !file.write(out.data(), std::streamsize(out.size()))) {
        if (error) *error = "it couldn't be written";
        return false;
    }
    return true;
}

bool vst3ReadPreset(const std::string& path, PluginPresetFile* out, std::string* error) {
    std::ifstream file(pathOf(path), std::ios::binary);
    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string in = buffer.str();
    if (in.size() < 48 || in.compare(0, 4, "VST3") != 0) {
        if (error) *error = "it isn't a VST3 preset";
        return false;
    }
    const std::string cid = in.substr(8, 32);
    const size_t list = size_t(getInt(in, 40, 8));
    if (list + 8 > in.size() || in.compare(list, 4, "List") != 0) {
        if (error) *error = "it isn't a VST3 preset";
        return false;
    }
    std::vector<uint8_t> comp, ctrl;
    std::string name;
    const uint64_t count = getInt(in, list + 4, 4);
    for (uint64_t i = 0; i < count; ++i) {
        const size_t at = list + 8 + size_t(i) * 20;
        if (at + 20 > in.size()) break;
        const std::string id = in.substr(at, 4);
        const size_t offset = size_t(getInt(in, at + 4, 8)), size = size_t(getInt(in, at + 12, 8));
        if (offset + size > in.size()) continue;
        if (id == "Comp") comp.assign(in.begin() + std::ptrdiff_t(offset), in.begin() + std::ptrdiff_t(offset + size));
        if (id == "Cont") ctrl.assign(in.begin() + std::ptrdiff_t(offset), in.begin() + std::ptrdiff_t(offset + size));
        if (id == "Info") {  // its name, if it gives one
            const std::string meta = in.substr(offset, size), key = "id=\"Name\" value=\"";
            const size_t from = meta.find(key);
            if (from != std::string::npos) name = meta.substr(from + key.size(), meta.find('"', from + key.size()) - from - key.size());
        }
    }
    if (comp.empty()) {
        if (error) *error = "it holds no settings";
        return false;
    }
    if (name.empty()) name = pathOf(path).stem().u8string();
    out->plugin_id = "VST3:" + cid;
    out->name = name;
    out->state.assign(kStateMagic, kStateMagic + 4);
    out->state.insert(out->state.end(), cid.begin(), cid.end());
    for (const auto* part : {&comp, &ctrl}) {
        for (int i = 0; i < 8; ++i) out->state.push_back(uint8_t(uint64_t(part->size()) >> (8 * i)));
        out->state.insert(out->state.end(), part->begin(), part->end());
    }
    return true;
}

}  // namespace sr
