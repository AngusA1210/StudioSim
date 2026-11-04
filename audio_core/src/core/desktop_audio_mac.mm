// macOS: desktop audio as a Core Audio process tap (macOS 14.2 or later) on every app's sound but StudioSim's, muted
// where it would have played while it is taken in, read through a private aggregate device of the tap and the
// computer's own output (its clock), as Apple's own example of a tap has it. See desktop_audio.h.

#include "desktop_audio.h"

#include <algorithm>
#include <vector>

#include <unistd.h>

#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include "interpolation.h"

namespace sr {

struct DesktopAudio::Platform {
    AudioObjectID tap = kAudioObjectUnknown;
    AudioObjectID aggregate = kAudioObjectUnknown;
    AudioDeviceIOProcID proc = nullptr;
    double rate = 48000.0;
    std::vector<float> stereo = std::vector<float>(8192 * 2);  // (a tap that comes in as two buffers, put together)
};

namespace {

AudioObjectPropertyAddress global(AudioObjectPropertySelector selector) {
    return {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

// The computer's own output (where the system's sound goes), by its UID, or nil.
NSString* systemOutputUID() {
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = global(kAudioHardwarePropertyDefaultSystemOutputDevice);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device) != noErr || device == kAudioObjectUnknown)
        return nil;
    CFStringRef uid = nullptr;
    size = sizeof(uid);
    address = global(kAudioDevicePropertyDeviceUID);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &uid) != noErr || uid == nullptr) return nil;
    return (__bridge_transfer NSString*)uid;
}

}  // namespace

DesktopAudio::DesktopAudio() { Sinc16::prepare(); }
DesktopAudio::~DesktopAudio() { stop(); }

bool DesktopAudio::startPlatform(std::string* error) {
    if (@available(macOS 14.2, *)) {
        @autoreleasepool {
            auto p = std::make_unique<Platform>();
            // Every app's sound but StudioSim's own (its process object, once it has played anything).
            pid_t pid = getpid();
            AudioObjectID me = kAudioObjectUnknown;
            UInt32 size = sizeof(me);
            AudioObjectPropertyAddress address = global(kAudioHardwarePropertyTranslatePIDToProcessObject);
            AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(pid), &pid, &size, &me);
            NSArray<NSNumber*>* leave_out = me != kAudioObjectUnknown ? @[ @(me) ] : @[];
            CATapDescription* description = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:leave_out];
            description.name = @"StudioSim desktop audio";
            description.privateTap = YES;
            description.muteBehavior = CATapMutedWhenTapped;  // (heard through StudioSim alone, as through a bridge)
            if (AudioHardwareCreateProcessTap(description, &p->tap) != noErr || p->tap == kAudioObjectUnknown) {
                *error = "macOS wouldn't let StudioSim take in the computer's sound";
                return false;
            }
            AudioStreamBasicDescription format{};
            size = sizeof(format);
            address = global(kAudioTapPropertyFormat);
            if (AudioObjectGetPropertyData(p->tap, &address, 0, nullptr, &size, &format) == noErr && format.mSampleRate > 0.0)
                p->rate = format.mSampleRate;

            // A private aggregate device of the tap, clocked by the computer's output, to read it through.
            NSString* output = systemOutputUID();
            NSMutableDictionary* aggregate = [@{
                @kAudioAggregateDeviceNameKey: @"StudioSim desktop audio",
                @kAudioAggregateDeviceUIDKey: [[NSUUID UUID] UUIDString],
                @kAudioAggregateDeviceIsPrivateKey: @YES,
                @kAudioAggregateDeviceIsStackedKey: @NO,
                @kAudioAggregateDeviceTapAutoStartKey: @YES,
                @kAudioAggregateDeviceTapListKey: @[ @{
                    @kAudioSubTapUIDKey: [description.UUID UUIDString],
                    @kAudioSubTapDriftCompensationKey: @YES,
                } ],
            } mutableCopy];
            if (output != nil) {  // (its streams, if it has any coming in, come before the tap's: see below)
                aggregate[@kAudioAggregateDeviceMainSubDeviceKey] = output;
                aggregate[@kAudioAggregateDeviceSubDeviceListKey] = @[ @{@kAudioSubDeviceUIDKey: output} ];
            }
            if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &p->aggregate) != noErr) {
                AudioHardwareDestroyProcessTap(p->tap);
                *error = "the computer's sound couldn't be taken in";
                return false;
            }
            Float64 rate = 0.0;
            size = sizeof(rate);
            address = global(kAudioDevicePropertyNominalSampleRate);
            if (AudioObjectGetPropertyData(p->aggregate, &address, 0, nullptr, &size, &rate) == noErr && rate > 0.0) p->rate = rate;

            Platform* platform = p.get();
            DesktopAudio* self = this;
            const OSStatus made = AudioDeviceCreateIOProcIDWithBlock(&p->proc, p->aggregate, nullptr,
                ^(const AudioTimeStamp*, const AudioBufferList* in, const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*) {
                    // The tap's two channels: one buffer of both (interleaved), or the last two of one each.
                    if (in == nullptr || in->mNumberBuffers == 0) return;
                    const AudioBuffer& last = in->mBuffers[in->mNumberBuffers - 1];
                    if (last.mData == nullptr) return;
                    if (last.mNumberChannels >= 2) {
                        const int frames = int(last.mDataByteSize / (sizeof(float) * last.mNumberChannels));
                        const float* data = static_cast<const float*>(last.mData);
                        if (last.mNumberChannels == 2) {
                            self->captured(data, frames, platform->rate);
                        } else {
                            const int n = std::min(frames, int(platform->stereo.size() / 2));
                            for (int i = 0; i < n; ++i) {
                                platform->stereo[size_t(2 * i)] = data[size_t(i) * last.mNumberChannels];
                                platform->stereo[size_t(2 * i + 1)] = data[size_t(i) * last.mNumberChannels + 1];
                            }
                            self->captured(platform->stereo.data(), n, platform->rate);
                        }
                    } else {
                        const AudioBuffer& first = in->mNumberBuffers >= 2 ? in->mBuffers[in->mNumberBuffers - 2] : last;
                        if (first.mData == nullptr) return;
                        const int frames = int(std::min(first.mDataByteSize, last.mDataByteSize) / sizeof(float));
                        const int n = std::min(frames, int(platform->stereo.size() / 2));
                        const float* l = static_cast<const float*>(first.mData);
                        const float* r = static_cast<const float*>(last.mData);
                        for (int i = 0; i < n; ++i) {
                            platform->stereo[size_t(2 * i)] = l[i];
                            platform->stereo[size_t(2 * i + 1)] = r[i];
                        }
                        self->captured(platform->stereo.data(), n, platform->rate);
                    }
                });
            if (made != noErr || AudioDeviceStart(p->aggregate, p->proc) != noErr) {
                if (p->proc) AudioDeviceDestroyIOProcID(p->aggregate, p->proc);
                AudioHardwareDestroyAggregateDevice(p->aggregate);
                AudioHardwareDestroyProcessTap(p->tap);
                *error = "the computer's sound couldn't be taken in";
                return false;
            }
            platform_ = std::move(p);
            return true;
        }
    }
    *error = "desktop audio needs macOS 14.2 or later";
    return false;
}

void DesktopAudio::stopPlatform() {
    if (!platform_) return;
    if (@available(macOS 14.2, *)) {
        AudioDeviceStop(platform_->aggregate, platform_->proc);
        AudioDeviceDestroyIOProcID(platform_->aggregate, platform_->proc);
        AudioHardwareDestroyAggregateDevice(platform_->aggregate);
        AudioHardwareDestroyProcessTap(platform_->tap);
    }
    platform_.reset();
}

}  // namespace sr
