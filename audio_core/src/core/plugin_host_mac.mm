// Audio Unit hosting on macOS: the effect plug-ins the system knows about, loaded into the game's process and played
// one channel at a time, with their own windows floating over the game.

#include "plugin_host.h"

#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <AudioToolbox/AUCocoaUIView.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/CoreAudioKit.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>

namespace sr {
namespace {

// Plug-ins are named by their type, subtype and maker codes, written in hex so that any byte survives the trip.
std::string hexCode(OSType v) {
    char s[9];
    std::snprintf(s, sizeof(s), "%08x", unsigned(v));
    return s;
}

bool parseId(const std::string& id, AudioComponentDescription& desc) {
    unsigned type = 0, subtype = 0, maker = 0;
    if (std::sscanf(id.c_str(), "AU:%8x:%8x:%8x", &type, &subtype, &maker) != 3) return false;
    desc = {OSType(type), OSType(subtype), OSType(maker), 0, 0};
    return true;
}

std::string toString(CFStringRef s) {
    if (!s) return {};
    const char* utf8 = [(__bridge NSString*)s UTF8String];
    return utf8 ? utf8 : "";
}

PluginDescription describe(AudioComponent component) {
    AudioComponentDescription d{};
    AudioComponentGetDescription(component, &d);
    PluginDescription out;
    out.id = "AU:" + hexCode(d.componentType) + ":" + hexCode(d.componentSubType) + ":" + hexCode(d.componentManufacturer);
    CFStringRef name = nullptr;
    AudioComponentCopyName(component, &name);  // "Maker: Name"
    const std::string full = toString(name);
    if (name) CFRelease(name);
    const size_t colon = full.find(": ");
    out.maker = colon == std::string::npos ? "" : full.substr(0, colon);
    out.name = colon == std::string::npos ? full : full.substr(colon + 2);
    std::vector<std::string> tags;  // what it says it is, if it says (few but Apple's do)
    AVAudioUnitComponent* about = [[AVAudioUnitComponentManager sharedAudioUnitComponentManager] componentsMatchingDescription:d].firstObject;
    for (NSString* tag in about.allTagNames) tags.push_back(tag.UTF8String ? tag.UTF8String : "");
    out.category = guessPluginCategory(out.name, out.maker, tags);
    return out;
}

// Waits for something the system finishes on another thread, or on this thread's run loop if this is the main thread
// (where a plug-in may need it to turn), for up to `seconds`.
template <class Done>
bool waitFor(Done&& done, double seconds) {
    const auto until = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    while (!done()) {
        if (std::chrono::steady_clock::now() > until) return false;
        if ([NSThread isMainThread]) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
        else std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return true;
}

AudioStreamBasicDescription streamFormat(double sample_rate, int channels) {
    AudioStreamBasicDescription f{};
    f.mSampleRate = sample_rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    f.mBytesPerPacket = f.mBytesPerFrame = sizeof(float);
    f.mFramesPerPacket = 1;
    f.mChannelsPerFrame = UInt32(channels);
    f.mBitsPerChannel = 32;
    return f;
}

struct Pending {
    std::atomic<bool> done{false};
    AudioComponentInstance unit = nullptr;
    OSStatus status = noErr;
};

// Loads a component asynchronously (version 3 plug-ins, and version 2 ones that must run in a separate process, such
// as Intel-only plug-ins on Apple silicon) and waits for it.
AudioUnit instantiate(AudioComponent component, AudioComponentInstantiationOptions options, OSStatus& status) {
    auto pending = std::make_shared<Pending>();
    AudioComponentInstantiate(component, options, ^(AudioComponentInstance instance, OSStatus error) {
      pending->unit = instance;
      pending->status = error;
      pending->done.store(true, std::memory_order_release);
    });
    if (!waitFor([&] { return pending->done.load(std::memory_order_acquire); }, 15.0)) {
        status = kAudioUnitErr_FailedInitialization;
        return nullptr;  // if it turns up later, it is never disposed of
    }
    status = pending->status;
    return pending->unit;
}

class AudioUnitPlugin final : public PluginInstance {
public:
    AudioUnitPlugin(AudioUnit unit, PluginDescription description) : unit_(unit), description_(std::move(description)) {}

    ~AudioUnitPlugin() override {
        if (window_) {
            if (resize_observer_) [[NSNotificationCenter defaultCenter] removeObserver:resize_observer_];
            [window_ orderOut:nil];
            window_.contentView = nil;
            window_ = nil;
        }
        view_controller_ = nil;
        if (initialized_) AudioUnitUninitialize(unit_);
        AudioComponentInstanceDispose(unit_);
    }

    const PluginDescription& description() const override { return description_; }

    bool prepare(double sample_rate, int max_frames, std::string* error) override {
        if (initialized_) {
            AudioUnitUninitialize(unit_);
            initialized_ = false;
        }
        sample_rate_ = sample_rate;
        UInt32 frames = UInt32(max_frames);
        AudioUnitSetProperty(unit_, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, sizeof(frames));
        AURenderCallbackStruct input{&AudioUnitPlugin::provideInput, this};
        HostCallbackInfo host{};
        host.hostUserData = this;
        host.beatAndTempoProc = &AudioUnitPlugin::beatAndTempo;
        AudioUnitSetProperty(unit_, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &host, sizeof(host));
        // One channel in and out if it will take that, which suits a pedal; otherwise stereo, or mono into stereo.
        const int layouts[3][2] = {{1, 1}, {2, 2}, {1, 2}};
        OSStatus status = kAudioUnitErr_FormatNotSupported;
        for (const auto& layout : layouts) {
            const AudioStreamBasicDescription in = streamFormat(sample_rate, layout[0]), out = streamFormat(sample_rate, layout[1]);
            if (AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &in, sizeof(in)) != noErr ||
                AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &out, sizeof(out)) != noErr ||
                AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &input, sizeof(input)) != noErr)
                continue;
            status = AudioUnitInitialize(unit_);
            if (status == noErr) {
                in_channels_ = layout[0];
                out_channels_ = layout[1];
                break;
            }
        }
        if (status != noErr) {
            if (error) *error = "it wouldn't start with one or two channels (error " + std::to_string(int(status)) + ")";
            return false;
        }
        initialized_ = true;
        max_frames_ = max_frames;
        input_.assign(size_t(max_frames), 0.0f);
        for (auto& side : output_) side.assign(size_t(max_frames), 0.0f);
        list_.assign(offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer), 0);
        Float64 latency = 0.0;
        UInt32 size = sizeof(latency);
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size) == noErr)
            latency_ = int(std::lround(latency * sample_rate));
        sample_time_ = 0.0;
        return true;
    }

    void process(float* io, int n) override {
        if (!initialized_ || n > max_frames_) return;
        std::copy(io, io + n, input_.begin());
        frames_now_ = n;
        auto* list = reinterpret_cast<AudioBufferList*>(list_.data());
        list->mNumberBuffers = UInt32(out_channels_);
        for (int c = 0; c < out_channels_; ++c) {
            list->mBuffers[c].mNumberChannels = 1;
            list->mBuffers[c].mDataByteSize = UInt32(n) * sizeof(float);
            list->mBuffers[c].mData = output_[c].data();
        }
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp stamp{};
        stamp.mSampleTime = sample_time_;
        stamp.mFlags = kAudioTimeStampSampleTimeValid;
        const OSStatus status = AudioUnitRender(unit_, &flags, &stamp, 0, UInt32(n), list);
        sample_time_ += n;
        if (status != noErr) return;  // the signal passes as it came
        const float* a = static_cast<const float*>(list->mBuffers[0].mData);
        if (out_channels_ == 1) {
            std::copy(a, a + n, io);
        } else {
            const float* b = static_cast<const float*>(list->mBuffers[1].mData);
            for (int i = 0; i < n; ++i) io[i] = 0.5f * (a[i] + b[i]);
        }
    }

    bool showEditor(const std::string& title) override {
        if (!window_) {
            NSView* view = makeView();
            if (!view) return false;
            const NSSize size = NSMakeSize(std::max(view.frame.size.width, 240.0), std::max(view.frame.size.height, 80.0));
            window_ = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
            window_.releasedWhenClosed = NO;
            window_.contentView = view;
            // Above the game, full screen or not, and on whichever space the game is on.
            window_.level = NSFloatingWindowLevel;
            window_.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace;
            // A plug-in that resizes its own view (many have a size menu) takes the window with it.
            view.postsFrameChangedNotifications = YES;
            NSWindow* window = window_;
            resize_observer_ = [[NSNotificationCenter defaultCenter] addObserverForName:NSViewFrameDidChangeNotification
                                                                                 object:view
                                                                                  queue:nil
                                                                             usingBlock:^(NSNotification* note) {
                                                                               NSView* changed = note.object;
                                                                               if (!NSEqualSizes(window.contentView.frame.size, changed.frame.size))
                                                                                   [window setContentSize:changed.frame.size];
                                                                             }];
            [window_ center];
        }
        window_.title = [NSString stringWithUTF8String:title.c_str()] ?: @"Plug-in";
        [window_ makeKeyAndOrderFront:nil];
        return true;
    }

    void hideEditor() override {
        if (window_) [window_ orderOut:nil];
    }

    bool editorVisible() const override { return window_ && window_.visible; }

    std::vector<uint8_t> saveState() const override {
        std::vector<uint8_t> out;
        CFPropertyListRef info = nullptr;
        UInt32 size = sizeof(info);
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, &size) != noErr || !info)
            return out;
        if (CFDataRef data = CFPropertyListCreateData(nullptr, info, kCFPropertyListBinaryFormat_v1_0, 0, nullptr)) {
            const uint8_t* bytes = CFDataGetBytePtr(data);
            out.assign(bytes, bytes + CFDataGetLength(data));
            CFRelease(data);
        }
        CFRelease(info);
        return out;
    }

    bool loadState(const std::vector<uint8_t>& state) override {
        if (state.empty()) return false;
        CFDataRef data = CFDataCreate(nullptr, state.data(), CFIndex(state.size()));
        CFPropertyListRef info = data ? CFPropertyListCreateWithData(nullptr, data, kCFPropertyListImmutable, nullptr, nullptr) : nullptr;
        if (data) CFRelease(data);
        if (!info) return false;
        const bool done = AudioUnitSetProperty(unit_, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &info, sizeof(info)) == noErr;
        CFRelease(info);
        if (done) {  // tell its window, if open, that every parameter may have changed
            AudioUnitParameter all{unit_, kAUParameterListener_AnyParameter, kAudioUnitScope_Global, 0};
            AUParameterListenerNotify(nullptr, nullptr, &all);
        }
        return done;
    }
    int latencySamples() const override { return latency_; }

    void setTempo(double bpm) override { tempo_.store(bpm, std::memory_order_relaxed); }

private:
    // What the plug-in hears: the pedal's input, in every channel it asks for (audio thread).
    static OSStatus provideInput(void* ref, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames,
                                 AudioBufferList* data) {
        auto* self = static_cast<AudioUnitPlugin*>(ref);
        const UInt32 have = std::min(frames, UInt32(self->frames_now_));
        for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
            auto* dst = static_cast<float*>(data->mBuffers[b].mData);
            if (!dst) {  // it would rather read from ours
                data->mBuffers[b].mData = self->input_.data();
                continue;
            }
            std::memcpy(dst, self->input_.data(), have * sizeof(float));
            if (frames > have) std::memset(dst + have, 0, (frames - have) * sizeof(float));
        }
        return noErr;
    }

    // The room's tempo, for plug-ins that keep time with the host (audio thread).
    static OSStatus beatAndTempo(void* ref, Float64* beat, Float64* tempo) {
        auto* self = static_cast<AudioUnitPlugin*>(ref);
        const double bpm = self->tempo_.load(std::memory_order_relaxed);
        if (tempo) *tempo = bpm;
        if (beat) *beat = self->sample_time_ / (self->sample_rate_ * 60.0 / bpm);
        return noErr;
    }

    NSView* makeView() {
        // A version 2 plug-in's own Cocoa view.
        UInt32 size = 0;
        Boolean writable = false;
        if (AudioUnitGetPropertyInfo(unit_, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr &&
            size >= sizeof(AudioUnitCocoaViewInfo)) {
            std::vector<uint8_t> memory(size);
            auto* info = reinterpret_cast<AudioUnitCocoaViewInfo*>(memory.data());
            if (AudioUnitGetProperty(unit_, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, info, &size) == noErr) {
                const size_t classes = (size - offsetof(AudioUnitCocoaViewInfo, mCocoaAUViewClass)) / sizeof(CFStringRef);
                NSView* view = nil;
                NSURL* url = (__bridge NSURL*)info->mCocoaAUViewBundleLocation;
                NSBundle* bundle = url ? [NSBundle bundleWithURL:url] : nil;
                Class factory_class = bundle && classes > 0 ? [bundle classNamed:(__bridge NSString*)info->mCocoaAUViewClass[0]] : nil;
                if (factory_class && [factory_class conformsToProtocol:@protocol(AUCocoaUIBase)]) {
                    id<AUCocoaUIBase> factory = [[factory_class alloc] init];
                    view = [factory uiViewForAudioUnit:unit_ withSize:NSZeroSize];
                }
                if (info->mCocoaAUViewBundleLocation) CFRelease(info->mCocoaAUViewBundleLocation);
                for (size_t i = 0; i < classes; ++i)
                    if (info->mCocoaAUViewClass[i]) CFRelease(info->mCocoaAUViewClass[i]);
                if (view) return view;
            }
        }
        // A version 3 plug-in's view controller.
        auto pending = std::make_shared<Pending>();
        __block NSViewController* controller = nil;
        view_request_ = ^(AUViewControllerBase* vc) {
          controller = vc;
          pending->done.store(true, std::memory_order_release);
        };
        void (^request)(AUViewControllerBase*) = view_request_;
        if (AudioUnitSetProperty(unit_, kAudioUnitProperty_RequestViewController, kAudioUnitScope_Global, 0, &request, sizeof(request)) == noErr &&
            waitFor([&] { return pending->done.load(std::memory_order_acquire); }, 5.0) && controller) {
            view_controller_ = controller;
            NSView* view = controller.view;
            const NSSize preferred = controller.preferredContentSize;
            if (preferred.width > 0 && preferred.height > 0) [view setFrameSize:preferred];
            return view;
        }
        // Otherwise a plain panel of its parameters, drawn by the system.
        AUGenericView* generic = [[AUGenericView alloc] initWithAudioUnit:unit_];
        generic.showsExpertParameters = YES;
        return generic;
    }

    AudioUnit unit_;
    PluginDescription description_;
    bool initialized_ = false;
    int in_channels_ = 1, out_channels_ = 1, max_frames_ = 0, latency_ = 0, frames_now_ = 0;
    double sample_rate_ = 48000.0, sample_time_ = 0.0;
    std::atomic<double> tempo_{120.0};
    std::vector<float> input_, output_[2];
    std::vector<uint8_t> list_;  // an AudioBufferList with room for two buffers
    NSWindow* window_ = nil;
    NSViewController* view_controller_ = nil;
    id resize_observer_ = nil;
    void (^view_request_)(AUViewControllerBase*) = nil;
};

}  // namespace

std::vector<PluginDescription> PluginInstance::available() {
    std::vector<PluginDescription> out;
    for (OSType type : {kAudioUnitType_Effect, kAudioUnitType_MusicEffect}) {
        AudioComponentDescription wanted{type, 0, 0, 0, 0};
        for (AudioComponent c = AudioComponentFindNext(nullptr, &wanted); c; c = AudioComponentFindNext(c, &wanted))
            out.push_back(describe(c));
    }
    auto lower = [](std::string s) {
        for (char& ch : s) ch = char(std::tolower(static_cast<unsigned char>(ch)));
        return s;
    };
    std::sort(out.begin(), out.end(), [&](const PluginDescription& a, const PluginDescription& b) {
        const std::string am = lower(a.maker), bm = lower(b.maker);
        return am != bm ? am < bm : lower(a.name) < lower(b.name);
    });
    out.erase(std::unique(out.begin(), out.end(), [](const PluginDescription& a, const PluginDescription& b) { return a.id == b.id; }),
              out.end());
    return out;
}

std::unique_ptr<PluginInstance> PluginInstance::load(const std::string& id, std::string* error) {
    AudioComponentDescription wanted{};
    if (!parseId(id, wanted)) {
        if (error) *error = "\"" + id + "\" isn't a plug-in";
        return nullptr;
    }
    AudioComponent component = AudioComponentFindNext(nullptr, &wanted);
    if (!component) {
        if (error) *error = "it isn't installed";
        return nullptr;
    }
    AudioComponentDescription found{};
    AudioComponentGetDescription(component, &found);
    OSStatus status = noErr;
    AudioUnit unit = nullptr;
    if (found.componentFlags & kAudioComponentFlag_IsV3AudioUnit) {
        unit = instantiate(component, 0, status);
    } else {
        status = AudioComponentInstanceNew(component, &unit);
        if (status != noErr || !unit)  // perhaps built only for Intel: it can still run in a process of its own
            unit = instantiate(component, kAudioComponentInstantiation_LoadOutOfProcess, status);
    }
    if (status != noErr || !unit) {
        if (error) *error = "it wouldn't load (error " + std::to_string(int(status)) + ")";
        return nullptr;
    }
    return std::make_unique<AudioUnitPlugin>(unit, describe(component));
}

}  // namespace sr
