// Audio Unit hosting on macOS: the plug-ins the system knows about, loaded into the game's process and played one
// channel at a time (or two, on a bus), with their own windows floating over the game.

#include "plugin_formats.h"

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

// A plug-in's window that never takes the keyboard from the game, so that the computer keyboard keeps playing while a
// knob in it is dragged, unless what is clicked in it is a box to type in. Many plug-ins try to take the keyboard when
// clicked (they make themselves first responder and their window key); here they can't.
@interface SRPluginPanel : NSPanel
@property(nonatomic) BOOL typing;  // a text box in it was clicked last: it may have the keyboard, for that
@end

@implementation SRPluginPanel
- (BOOL)canBecomeKeyWindow {
    return self.typing;
}
- (void)sendEvent:(NSEvent*)event {
    if (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown) {
        NSView* hit = [self.contentView hitTest:[self.contentView.superview convertPoint:event.locationInWindow fromView:nil]];
        self.typing = [hit isKindOfClass:[NSTextView class]] || [hit isKindOfClass:[NSTextField class]];
    }
    [super sendEvent:event];
}
@end

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
    out.instrument = d.componentType == kAudioUnitType_MusicDevice;
    out.category = out.instrument ? guessInstrumentCategory(out.name, out.maker, tags) : guessPluginCategory(out.name, out.maker, tags);
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

    bool isInstrument() const override { return description_.instrument; }

    ~AudioUnitPlugin() override {
        if (window_) {
            if (resize_observer_) [[NSNotificationCenter defaultCenter] removeObserver:resize_observer_];
            if (key_monitor_) [NSEvent removeMonitor:key_monitor_];
            [window_ orderOut:nil];
            window_.contentView = nil;
            window_ = nil;
        }
        view_controller_ = nil;
        if (initialized_) AudioUnitUninitialize(unit_);
        AudioComponentInstanceDispose(unit_);
    }

    const PluginDescription& description() const override { return description_; }

    bool prepare(double sample_rate, int max_frames, std::string* error, bool stereo = false) override {
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
        OSStatus status = kAudioUnitErr_FormatNotSupported;
        // An instrument has no input to give it: stereo out if it will, or one channel.
        for (int channels : {2, 1}) {
            if (!description_.instrument) break;
            const AudioStreamBasicDescription out = streamFormat(sample_rate, channels);
            if (AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &out, sizeof(out)) != noErr) continue;
            status = AudioUnitInitialize(unit_);
            if (status == noErr) {
                in_channels_ = 0;
                out_channels_ = channels;
                break;
            }
        }
        // An effect: one channel in and out if it will take that, which suits a pedal; otherwise stereo, or mono into
        // stereo. On a bus, stereo first.
        const int mono_first[3][2] = {{1, 1}, {2, 2}, {1, 2}}, stereo_first[3][2] = {{2, 2}, {1, 2}, {1, 1}};
        for (const auto& layout : stereo ? stereo_first : mono_first) {
            if (description_.instrument) break;
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
        input_right_.assign(size_t(max_frames), 0.0f);
        stereo_in_ = false;
        for (auto& side : output_) side.assign(size_t(max_frames), 0.0f);
        list_.assign(offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer), 0);
        Float64 latency = 0.0;
        UInt32 size = sizeof(latency);
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size) == noErr)
            latency_ = int(std::lround(latency * sample_rate));
        sample_time_ = 0.0;
        return true;
    }

    void midi(uint8_t status, uint8_t data1, uint8_t data2, int offset) override {
        if (initialized_) MusicDeviceMIDIEvent(unit_, status, data1, data2, UInt32(std::max(offset, 0)));
    }

    void render(float* out, int n) override {
        if (!initialized_ || n > max_frames_ || !description_.instrument) return;
        frames_now_ = 0;
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
        if (status != noErr) return;
        const float* a = static_cast<const float*>(list->mBuffers[0].mData);
        const float* b = out_channels_ > 1 ? static_cast<const float*>(list->mBuffers[1].mData) : a;
        for (int i = 0; i < n; ++i) out[i] += 0.5f * (a[i] + b[i]);
    }

    void processStereo(float* left, float* right, int n) override {
        if (!initialized_ || n > max_frames_ || description_.instrument) return;
        if (in_channels_ < 2 && out_channels_ < 2) {  // a one-channel plug-in: the two together, played in both
            PluginInstance::processStereo(left, right, n);
            return;
        }
        if (in_channels_ >= 2) {
            std::copy(left, left + n, input_.begin());
            std::copy(right, right + n, input_right_.begin());
        } else {
            for (int i = 0; i < n; ++i) input_[size_t(i)] = 0.5f * (left[i] + right[i]);
        }
        stereo_in_ = in_channels_ >= 2;
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
        stereo_in_ = false;
        if (status != noErr) return;  // the signal passes as it came
        const float* a = static_cast<const float*>(list->mBuffers[0].mData);
        const float* b = out_channels_ > 1 ? static_cast<const float*>(list->mBuffers[1].mData) : a;
        std::copy(a, a + n, left);
        std::copy(b, b + n, right);
    }

    void process(float* io, int n) override {
        if (!initialized_ || n > max_frames_ || description_.instrument) return;
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
            // A panel that takes the keyboard only when something in it needs typing into (a text box), so that the
            // game keeps the keys with the window open: notes still play, Tab still closes the mix window.
            SRPluginPanel* panel = [[SRPluginPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
            panel.becomesKeyOnlyIfNeeded = YES;
            panel.hidesOnDeactivate = NO;
            window_ = panel;
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
            // Should one take the keyboard all the same (a text box clicked, or a plug-in that insists), it goes back to
            // the game once the click is done, unless what was clicked is something to type in.
            __weak NSPanel* watched = panel;
            key_monitor_ = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)
                                                                 handler:^NSEvent*(NSEvent* event) {
                                                                   if (event.window != watched) return event;
                                                                   dispatch_async(dispatch_get_main_queue(), ^{
                                                                     NSPanel* clicked = watched;
                                                                     if (!clicked || !clicked.isKeyWindow) return;
                                                                     const id responder = clicked.firstResponder;
                                                                     if ([responder isKindOfClass:[NSTextView class]] ||
                                                                         [responder isKindOfClass:[NSTextField class]])
                                                                         return;  // being typed into
                                                                     for (NSWindow* w in NSApp.orderedWindows)
                                                                         if (![w isKindOfClass:[NSPanel class]] && w.isVisible && w.canBecomeKeyWindow) {
                                                                             [w makeKeyWindow];
                                                                             break;
                                                                         }
                                                                   });
                                                                   return event;
                                                                 }];
        }
        window_.title = [NSString stringWithUTF8String:title.c_str()] ?: @"Plug-in";
        [window_ orderFront:nil];  // in front, but leaving the keyboard with the game
        return true;
    }

    void placeEditor(double above_bottom) override {
        if (!window_) return;
        NSWindow* game = nil;  // the frontmost window that isn't one of the plug-ins' panels
        for (NSWindow* w in NSApp.orderedWindows)
            if (w != window_ && ![w isKindOfClass:[NSPanel class]] && w.isVisible) {
                game = w;
                break;
            }
        if (!game) return;
        const NSRect content = [game contentRectForFrameRect:game.frame];
        const NSRect screen = (game.screen ?: NSScreen.mainScreen).visibleFrame;
        NSRect f = window_.frame;
        f.origin.x = NSMidX(content) - f.size.width / 2;
        f.origin.y = content.origin.y + content.size.height * std::clamp(above_bottom, 0.0, 1.0);
        f.origin.y = std::max(std::min(f.origin.y, NSMaxY(screen) - f.size.height), NSMinY(screen));
        f.origin.x = std::max(std::min(f.origin.x, NSMaxX(screen) - f.size.width), NSMinX(screen));
        [window_ setFrame:f display:YES];
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
    std::vector<PluginParameter> parameters() const override {
        std::vector<PluginParameter> out;
        UInt32 size = 0;
        Boolean writable = false;
        if (AudioUnitGetPropertyInfo(unit_, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, &writable) != noErr || size == 0)
            return out;
        std::vector<AudioUnitParameterID> ids(size / sizeof(AudioUnitParameterID));
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, ids.data(), &size) != noErr) return out;
        for (AudioUnitParameterID id : ids) {
            AudioUnitParameterInfo info{};
            UInt32 info_size = sizeof(info);
            if (AudioUnitGetProperty(unit_, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &info, &info_size) != noErr) continue;
            // Only what can be set, and not a meter.
            if (!(info.flags & kAudioUnitParameterFlag_IsWritable) || (info.flags & kAudioUnitParameterFlag_MeterReadOnly)) continue;
            PluginParameter p;
            p.id = id;
            if ((info.flags & kAudioUnitParameterFlag_HasCFNameString) && info.cfNameString) {
                p.name = toString(info.cfNameString);
                if (info.flags & kAudioUnitParameterFlag_CFNameRelease) CFRelease(info.cfNameString);
            } else {
                p.name = info.name;
            }
            static const std::pair<AudioUnitParameterUnit, const char*> kUnits[] = {
                {kAudioUnitParameterUnit_Decibels, "dB"}, {kAudioUnitParameterUnit_Hertz, "Hz"}, {kAudioUnitParameterUnit_Percent, "%"},
                {kAudioUnitParameterUnit_Seconds, "s"}, {kAudioUnitParameterUnit_Milliseconds, "ms"}, {kAudioUnitParameterUnit_Cents, "cents"}};
            for (const auto& [unit, name] : kUnits)
                if (info.unit == unit) p.unit = name;
            p.min = info.minValue;
            p.max = info.maxValue > info.minValue ? info.maxValue : info.minValue + 1.0f;
            p.initial = info.defaultValue;
            if (!p.name.empty()) out.push_back(p);
        }
        return out;
    }

    float parameter(uint32_t id) const override {
        AudioUnitParameterValue value = 0.0f;
        AudioUnitGetParameter(unit_, id, kAudioUnitScope_Global, 0, &value);
        return value;
    }

    void setParameter(uint32_t id, float value) override { AudioUnitSetParameter(unit_, id, kAudioUnitScope_Global, 0, value, 0); }

    void notifyParameter(uint32_t id) override {
        AudioUnitParameter p{unit_, id, kAudioUnitScope_Global, 0};
        AUParameterListenerNotify(nullptr, nullptr, &p);
    }

    std::vector<std::string> factoryPresets() const override {
        std::vector<std::string> out;
        CFArrayRef presets = nullptr;
        UInt32 size = sizeof(presets);
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0, &presets, &size) != noErr || !presets)
            return out;
        for (CFIndex i = 0; i < CFArrayGetCount(presets); ++i) {
            const auto* preset = static_cast<const AUPreset*>(CFArrayGetValueAtIndex(presets, i));
            out.push_back(preset ? toString(preset->presetName) : "");
        }
        CFRelease(presets);
        return out;
    }

    bool loadFactoryPreset(int index) override {
        CFArrayRef presets = nullptr;
        UInt32 size = sizeof(presets);
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0, &presets, &size) != noErr || !presets)
            return false;
        bool done = false;
        if (index >= 0 && index < CFArrayGetCount(presets)) {
            const AUPreset preset = *static_cast<const AUPreset*>(CFArrayGetValueAtIndex(presets, index));
            done = AudioUnitSetProperty(unit_, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &preset, sizeof(preset)) == noErr;
        }
        CFRelease(presets);
        if (done) {
            AudioUnitParameter all{unit_, kAUParameterListener_AnyParameter, kAudioUnitScope_Global, 0};
            AUParameterListenerNotify(nullptr, nullptr, &all);
        }
        return done;
    }

    // As it reports it now (it can change: a lookahead switched on, say), or as it was when prepared if it won't say.
    int latencySamples() const override {
        Float64 latency = 0.0;
        UInt32 size = sizeof(latency);
        if (AudioUnitGetProperty(unit_, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size) == noErr)
            return int(std::lround(latency * sample_rate_));
        return latency_;
    }

    void setTempo(double bpm) override { tempo_.store(bpm, std::memory_order_relaxed); }

private:
    // What the plug-in hears: the pedal's input, in every channel it asks for (audio thread).
    static OSStatus provideInput(void* ref, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames,
                                 AudioBufferList* data) {
        auto* self = static_cast<AudioUnitPlugin*>(ref);
        const UInt32 have = std::min(frames, UInt32(self->frames_now_));
        for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
            auto* dst = static_cast<float*>(data->mBuffers[b].mData);
            const std::vector<float>& from = self->stereo_in_ && b == 1 ? self->input_right_ : self->input_;  // (a bus's right)
            if (!dst) {  // it would rather read from ours
                data->mBuffers[b].mData = const_cast<float*>(from.data());
                continue;
            }
            std::memcpy(dst, from.data(), have * sizeof(float));
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
    std::vector<float> input_, input_right_, output_[2];
    bool stereo_in_ = false;  // processing a bus's two channels: the second buffer it asks for is the right
    std::vector<uint8_t> list_;  // an AudioBufferList with room for two buffers
    NSWindow* window_ = nil;
    NSViewController* view_controller_ = nil;
    id resize_observer_ = nil;
    id key_monitor_ = nil;
    void (^view_request_)(AUViewControllerBase*) = nil;
};

}  // namespace

std::vector<PluginDescription> auPlugins(bool instruments) {
    std::vector<PluginDescription> out;
    const std::vector<OSType> types = instruments ? std::vector<OSType>{kAudioUnitType_MusicDevice}
                                                  : std::vector<OSType>{kAudioUnitType_Effect, kAudioUnitType_MusicEffect};
    for (OSType type : types) {
        AudioComponentDescription wanted{type, 0, 0, 0, 0};
        for (AudioComponent c = AudioComponentFindNext(nullptr, &wanted); c; c = AudioComponentFindNext(c, &wanted))
            out.push_back(describe(c));
    }
    std::sort(out.begin(), out.end(), [](const PluginDescription& a, const PluginDescription& b) { return a.id < b.id; });
    out.erase(std::unique(out.begin(), out.end(), [](const PluginDescription& a, const PluginDescription& b) { return a.id == b.id; }),
              out.end());
    return out;
}

std::unique_ptr<PluginInstance> auLoad(const std::string& id, std::string* error) {
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

bool auWritePreset(const std::string& path, const std::string& name, const std::vector<uint8_t>& state, std::string* error) {
    @autoreleasepool {
        NSData* data = [NSData dataWithBytes:state.data() length:state.size()];
        id info = state.empty() ? nil : [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers
                                                                                   format:nullptr error:nil];
        if (![info isKindOfClass:[NSMutableDictionary class]]) {
            if (error) *error = "there are no settings to save";
            return false;
        }
        NSMutableDictionary* preset = info;
        preset[@kAUPresetNameKey] = [NSString stringWithUTF8String:name.c_str()] ?: @"Preset";
        NSData* xml = [NSPropertyListSerialization dataWithPropertyList:preset format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        NSString* file = [NSString stringWithUTF8String:path.c_str()];
        NSError* problem = nil;
        if (!xml || !file ||
            ![[NSFileManager defaultManager] createDirectoryAtPath:[file stringByDeletingLastPathComponent] withIntermediateDirectories:YES
                                                        attributes:nil error:&problem] ||
            ![xml writeToFile:file options:NSDataWritingAtomic error:&problem]) {
            if (error) *error = problem ? problem.localizedDescription.UTF8String : "it couldn't be written";
            return false;
        }
        return true;
    }
}

bool auReadPreset(const std::string& path, PluginPresetFile* out, std::string* error) {
    @autoreleasepool {
        NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path.c_str()] ?: @""];
        id info = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nullptr error:nil] : nil;
        NSDictionary* preset = [info isKindOfClass:[NSDictionary class]] ? info : nil;
        NSNumber* type = preset[@kAUPresetTypeKey];
        NSNumber* subtype = preset[@kAUPresetSubtypeKey];
        NSNumber* maker = preset[@kAUPresetManufacturerKey];
        if (![type isKindOfClass:[NSNumber class]] || ![subtype isKindOfClass:[NSNumber class]] || ![maker isKindOfClass:[NSNumber class]]) {
            if (error) *error = "it isn't an Audio Unit preset";
            return false;
        }
        out->plugin_id = "AU:" + hexCode(OSType(type.unsignedIntValue)) + ":" + hexCode(OSType(subtype.unsignedIntValue)) + ":" +
                         hexCode(OSType(maker.unsignedIntValue));
        NSString* name = preset[@kAUPresetNameKey];
        out->name = [name isKindOfClass:[NSString class]] && name.UTF8String ? name.UTF8String : "";
        NSData* binary = [NSPropertyListSerialization dataWithPropertyList:preset format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        const auto* bytes = static_cast<const uint8_t*>(binary.bytes);
        out->state.assign(bytes, bytes + binary.length);
        return !out->state.empty();
    }
}

}  // namespace sr
