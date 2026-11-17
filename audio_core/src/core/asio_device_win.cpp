#include "asio_device.h"
#include "sample_rates.h"

#include <windows.h>
#include <objbase.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <map>
#include <mutex>
#include <utility>

// Steinberg's ASIO SDK (thirdparty/asiosdk/common): the driver interface and its types.
#include "asiosys.h"
#include "asio.h"
#include "iasiodrv.h"

namespace sr {
namespace {

constexpr int kMaxChannels = 64;  // of each, inputs and outputs: more than any interface StudioSim routes to

std::string narrow(const wchar_t* text) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    if (size <= 1) return {};
    std::string out(size_t(size - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr, nullptr);
    return out;
}

struct InstalledDriver {
    std::string name;  // with the prefix, as the device lists show it
    CLSID clsid{};
};

// Each driver is a key under HKLM\SOFTWARE\ASIO, named as the interface's maker named it, holding its COM class.
std::vector<InstalledDriver> installed() {
    std::vector<InstalledDriver> out;
    HKEY root;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\ASIO", 0, KEY_READ | KEY_WOW64_64KEY, &root) != ERROR_SUCCESS) return out;
    wchar_t key[256];
    for (DWORD i = 0;; ++i) {
        DWORD length = DWORD(std::size(key));
        if (RegEnumKeyExW(root, i, key, &length, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS) break;
        wchar_t clsid[64] = {};
        DWORD bytes = sizeof(clsid);
        if (RegGetValueW(root, key, L"CLSID", RRF_RT_REG_SZ, nullptr, clsid, &bytes) != ERROR_SUCCESS) continue;
        InstalledDriver d;
        if (CLSIDFromString(clsid, &d.clsid) != NOERROR) continue;
        d.name = kAsioPrefix + narrow(key);
        out.push_back(d);
    }
    RegCloseKey(root);
    return out;
}

// What each driver was found to have when it was last opened.
std::mutex known_mutex;
std::map<std::string, std::pair<int, int>> known_channels;

// ASIO's callbacks carry no pointer back, which is one reason a process runs one driver at a time.
std::atomic<AsioStream*> active{nullptr};
std::atomic<bool> reset_wanted{false};

// ── Sample formats (little-endian, as on every Windows machine) ─────────────────────────────────────────────
bool readable(long type) {
    switch (type) {
        case ASIOSTInt16LSB: case ASIOSTInt24LSB: case ASIOSTInt32LSB: case ASIOSTFloat32LSB: case ASIOSTFloat64LSB:
        case ASIOSTInt32LSB16: case ASIOSTInt32LSB18: case ASIOSTInt32LSB20: case ASIOSTInt32LSB24:
            return true;
        default:
            return false;
    }
}

int bytesOf(long type) {
    switch (type) {
        case ASIOSTInt16LSB: return 2;
        case ASIOSTInt24LSB: return 3;
        case ASIOSTFloat64LSB: return 8;
        default: return 4;
    }
}

// How many bits of a 32-bit sample the format uses (the rest sign-extend them).
int bitsOf(long type) {
    switch (type) {
        case ASIOSTInt32LSB16: return 16;
        case ASIOSTInt32LSB18: return 18;
        case ASIOSTInt32LSB20: return 20;
        case ASIOSTInt32LSB24: return 24;
        default: return 32;
    }
}

// One channel of the driver's buffer into every `stride`th float.
void toFloat(long type, const void* from, float* to, int stride, int frames) {
    switch (type) {
        case ASIOSTInt16LSB: {
            const auto* s = static_cast<const int16_t*>(from);
            for (int i = 0; i < frames; ++i) to[size_t(i) * size_t(stride)] = float(s[i]) * (1.0f / 32768.0f);
            break;
        }
        case ASIOSTInt24LSB: {
            const auto* b = static_cast<const uint8_t*>(from);
            for (int i = 0; i < frames; ++i, b += 3) {
                const int32_t v = int32_t(uint32_t(b[0]) << 8 | uint32_t(b[1]) << 16 | uint32_t(b[2]) << 24) >> 8;
                to[size_t(i) * size_t(stride)] = float(v) * (1.0f / 8388608.0f);
            }
            break;
        }
        case ASIOSTFloat32LSB: {
            const auto* s = static_cast<const float*>(from);
            for (int i = 0; i < frames; ++i) to[size_t(i) * size_t(stride)] = s[i];
            break;
        }
        case ASIOSTFloat64LSB: {
            const auto* s = static_cast<const double*>(from);
            for (int i = 0; i < frames; ++i) to[size_t(i) * size_t(stride)] = float(s[i]);
            break;
        }
        default: {  // 32-bit integers, all or some of their bits used
            const auto* s = static_cast<const int32_t*>(from);
            const float scale = 1.0f / float(1u << (bitsOf(type) - 1));
            for (int i = 0; i < frames; ++i) to[size_t(i) * size_t(stride)] = float(s[i]) * scale;
            break;
        }
    }
}

// Every `stride`th float into one channel of the driver's buffer, clipped to full scale.
void fromFloat(long type, const float* from, int stride, void* to, int frames) {
    const auto at = [&](int i) { return std::clamp(from[size_t(i) * size_t(stride)], -1.0f, 1.0f); };
    switch (type) {
        case ASIOSTInt16LSB: {
            auto* d = static_cast<int16_t*>(to);
            for (int i = 0; i < frames; ++i) d[i] = int16_t(std::lrint(at(i) * 32767.0f));
            break;
        }
        case ASIOSTInt24LSB: {
            auto* b = static_cast<uint8_t*>(to);
            for (int i = 0; i < frames; ++i, b += 3) {
                const auto v = uint32_t(int32_t(std::lrint(double(at(i)) * 8388607.0)));
                b[0] = uint8_t(v), b[1] = uint8_t(v >> 8), b[2] = uint8_t(v >> 16);
            }
            break;
        }
        case ASIOSTFloat32LSB: {
            auto* d = static_cast<float*>(to);
            for (int i = 0; i < frames; ++i) d[i] = at(i);
            break;
        }
        case ASIOSTFloat64LSB: {
            auto* d = static_cast<double*>(to);
            for (int i = 0; i < frames; ++i) d[i] = double(at(i));
            break;
        }
        default: {
            auto* d = static_cast<int32_t*>(to);
            const double scale = double((1u << (bitsOf(type) - 1)) - 1u);
            for (int i = 0; i < frames; ++i) d[i] = int32_t(std::lrint(double(at(i)) * scale));
            break;
        }
    }
}

// The buffer size nearest the one asked for that the driver allows: any step of `granularity` from its smallest to its
// largest, or powers of two between them when it says -1.
int chooseBufferSize(int wanted, long smallest, long largest, long preferred, long granularity) {
    if (smallest <= 0 || largest < smallest) return int(preferred);
    long best = preferred;
    const auto consider = [&](long size) {
        if (size >= smallest && size <= largest && std::labs(size - wanted) < std::labs(best - wanted)) best = size;
    };
    if (granularity == -1) {
        for (long size = 1; size <= largest; size *= 2) consider(size);
    } else if (granularity > 0) {
        for (long size = smallest; size <= largest; size += granularity) consider(size);
    }
    return int(std::clamp(best, smallest, largest));
}

}  // namespace

// What the driver calls, on its own thread.
struct AsioCallbacks {
    static void bufferSwitch(long index, ASIOBool) {
        if (AsioStream* s = active.load(std::memory_order_acquire)) s->bufferSwitch(index);
    }
    static ASIOTime* bufferSwitchTimeInfo(ASIOTime*, long index, ASIOBool direct) {
        bufferSwitch(index, direct);
        return nullptr;
    }
    static void sampleRateDidChange(ASIOSampleRate) { reset_wanted.store(true, std::memory_order_relaxed); }
    static long asioMessage(long selector, long value, void*, double*) {
        switch (selector) {
            case kAsioSelectorSupported:
                return value == kAsioEngineVersion || value == kAsioResetRequest || value == kAsioResyncRequest ||
                       value == kAsioLatenciesChanged || value == kAsioSupportsTimeInfo;
            case kAsioEngineVersion: return 2;
            case kAsioResetRequest: reset_wanted.store(true, std::memory_order_relaxed); return 1;
            case kAsioResyncRequest: return 1;     // (it dropped out and caught up: nothing to redo)
            case kAsioLatenciesChanged: return 1;
            case kAsioSupportsTimeInfo: return 0;  // bufferSwitch is all it needs
            default: return 0;
        }
    }
};

std::vector<AsioDriverInfo> asioDrivers() {
    std::vector<AsioDriverInfo> out;
    std::lock_guard<std::mutex> lock(known_mutex);
    for (const InstalledDriver& d : installed()) {
        AsioDriverInfo info;
        info.name = d.name;
        if (const auto known = known_channels.find(d.name); known != known_channels.end())
            std::tie(info.inputs, info.outputs) = known->second;
        out.push_back(info);
    }
    return out;
}

AsioStream::~AsioStream() { close(); }

bool AsioStream::resetWanted() const { return reset_wanted.load(std::memory_order_relaxed); }

bool AsioStream::open(const std::string& name, int buffer_size, bool with_input, int wanted_rate, std::string* error) {
    close();
    const auto fail = [&](const std::string& why) {
        if (error) *error = why;
        close();
        return false;
    };
    const std::vector<InstalledDriver> drivers = installed();
    const auto found = std::find_if(drivers.begin(), drivers.end(), [&](const InstalledDriver& d) { return d.name == name; });
    if (found == drivers.end()) return fail("the ASIO driver \"" + name.substr(std::strlen(kAsioPrefix)) + "\" is not installed");
    if (active.load(std::memory_order_acquire)) return fail("another ASIO driver is already running");
    const std::string driver_name = name.substr(std::strlen(kAsioPrefix));

    // (S_FALSE: COM was already set up on this thread; that still has to be balanced. A thread set up for the other
    // threading model refuses, which most drivers work with anyway.)
    com_ok_ = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED));
    IASIO* driver = nullptr;
    // (An ASIO driver's interface id is its class id.)
    if (FAILED(CoCreateInstance(found->clsid, nullptr, CLSCTX_INPROC_SERVER, found->clsid, reinterpret_cast<void**>(&driver))) || !driver)
        return fail("could not load the ASIO driver \"" + driver_name + "\"");
    driver_ = driver;
    if (!driver->init(GetDesktopWindow())) {
        char message[128] = {};
        driver->getErrorMessage(message);
        return fail(driver_name + " would not start" + (message[0] ? std::string(": ") + message : std::string()) +
                    " (is another program using it?)");
    }

    long ins = 0, outs = 0;
    if (driver->getChannels(&ins, &outs) != ASE_OK || outs <= 0) return fail(driver_name + " has no outputs");
    {
        std::lock_guard<std::mutex> lock(known_mutex);
        known_channels[name] = {int(ins), int(outs)};
    }

    // Run at the rate asked for, or at whatever it is set to (its control panel's, or another program's) if StudioSim
    // can run at that; otherwise it is set to the one StudioSim runs at, as a DAW sets an interface to its session's.
    ASIOSampleRate rate = 0;
    if (driver->getSampleRate(&rate) != ASE_OK) rate = 0;
    const int target = chooseEngineRate(wanted_rate, int(std::lround(rate)));
    if (int(std::lround(rate)) != target) {
        if (driver->canSampleRate(ASIOSampleRate(target)) != ASE_OK || driver->setSampleRate(ASIOSampleRate(target)) != ASE_OK)
            return fail(driver_name + " won't run at " + (target == 44100 ? "44.1" : "48") + " kHz (StudioSim runs at 44.1 or 48 kHz)");
    }
    rate_ = target;

    long smallest = 0, largest = 0, preferred = 0, granularity = 0;
    if (driver->getBufferSize(&smallest, &largest, &preferred, &granularity) != ASE_OK || preferred <= 0)
        return fail(driver_name + " did not say what buffer sizes it allows");
    buffer_ = chooseBufferSize(buffer_size, smallest, largest, preferred, granularity);

    const int in_count = with_input ? int(std::min<long>(ins, kMaxChannels)) : 0;
    const int out_count = int(std::min<long>(outs, kMaxChannels));
    std::vector<ASIOBufferInfo> infos(size_t(in_count + out_count));
    for (int i = 0; i < in_count + out_count; ++i) {
        infos[size_t(i)].isInput = i < in_count ? ASIOTrue : ASIOFalse;
        infos[size_t(i)].channelNum = i < in_count ? i : i - in_count;
    }
    static ASIOCallbacks callbacks = {&AsioCallbacks::bufferSwitch, &AsioCallbacks::sampleRateDidChange,
                                      &AsioCallbacks::asioMessage, &AsioCallbacks::bufferSwitchTimeInfo};
    if (driver->createBuffers(infos.data(), long(infos.size()), buffer_, &callbacks) != ASE_OK)
        return fail(driver_name + " would not run with a buffer of " + std::to_string(buffer_) + " samples");
    buffers_ok_ = true;

    for (const ASIOBufferInfo& info : infos) {
        ASIOChannelInfo detail{};
        detail.channel = info.channelNum;
        detail.isInput = info.isInput;
        if (driver->getChannelInfo(&detail) != ASE_OK) return fail(driver_name + " did not describe its channels");
        if (!readable(detail.type))
            return fail(driver_name + " uses a sample format StudioSim can't read (ASIO type " + std::to_string(detail.type) + ")");
        Channel c;
        c.buffers[0] = info.buffers[0];
        c.buffers[1] = info.buffers[1];
        c.type = detail.type;
        (info.isInput ? inputs_ : outputs_).push_back(c);
    }

    long input_latency = 0, output_latency = 0;
    if (driver->getLatencies(&input_latency, &output_latency) == ASE_OK) {
        input_latency_ = int(input_latency);
        output_latency_ = int(output_latency);
    }
    output_ready_ = driver->outputReady() == ASE_OK;
    in_.assign(size_t(in_count) * size_t(buffer_), 0.0f);
    out_.assign(size_t(out_count) * size_t(buffer_), 0.0f);
    reset_wanted.store(false, std::memory_order_relaxed);
    return true;
}

bool AsioStream::start(Callback callback, void* user, std::string* error) {
    if (!buffers_ok_) {
        if (error) *error = "the ASIO driver is not open";
        return false;
    }
    callback_ = callback;
    user_ = user;
    for (const Channel& c : outputs_)  // (both halves silent, in case the driver plays one before the first callback)
        for (void* half : c.buffers) std::memset(half, 0, size_t(bytesOf(c.type)) * size_t(buffer_));
    active.store(this, std::memory_order_release);
    if (static_cast<IASIO*>(driver_)->start() != ASE_OK) {
        active.store(nullptr, std::memory_order_release);
        if (error) *error = "the ASIO driver would not start";
        return false;
    }
    running_ = true;
    return true;
}

void AsioStream::close() {
    auto* driver = static_cast<IASIO*>(driver_);
    if (running_) driver->stop();
    running_ = false;
    if (active.load(std::memory_order_acquire) == this) active.store(nullptr, std::memory_order_release);
    if (buffers_ok_) driver->disposeBuffers();
    buffers_ok_ = false;
    if (driver) driver->Release();
    driver_ = nullptr;
    if (com_ok_) CoUninitialize();
    com_ok_ = false;
    inputs_.clear();
    outputs_.clear();
    output_ready_ = false;
}

void AsioStream::bufferSwitch(long index) {
    index &= 1;
    const int frames = buffer_, in_count = inputs(), out_count = outputs();
    for (int c = 0; c < in_count; ++c) toFloat(inputs_[size_t(c)].type, inputs_[size_t(c)].buffers[index], in_.data() + c, in_count, frames);
    callback_(user_, in_count ? in_.data() : nullptr, in_count, out_.data(), out_count, frames);
    for (int c = 0; c < out_count; ++c) fromFloat(outputs_[size_t(c)].type, out_.data() + c, out_count, outputs_[size_t(c)].buffers[index], frames);
    if (output_ready_) static_cast<IASIO*>(driver_)->outputReady();
}

}  // namespace sr
