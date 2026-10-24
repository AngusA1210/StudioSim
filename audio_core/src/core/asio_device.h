#pragma once
// ASIO on Windows: the drivers audio interfaces ship for low latency, which bypass Windows' own audio. Built only
// when Steinberg's ASIO SDK is in thirdparty/asiosdk (SR_ASIO); otherwise there are no ASIO drivers to choose.
//
// A driver is one device with inputs and outputs on one clock, so it is chosen as the output and its own inputs are
// the live input. Only one driver can be loaded at a time, and it is loaded, run and let go from the thread that opens
// it (the drivers are COM objects that expect that).

#include <string>
#include <vector>

namespace sr {

// What an ASIO driver is called in the device lists, to keep it apart from the same interface seen through WASAPI.
inline constexpr char kAsioPrefix[] = "ASIO: ";
inline bool isAsioDevice(const std::string& name) { return name.rfind(kAsioPrefix, 0) == 0; }

struct AsioDriverInfo {
    std::string name;            // as the device lists show it ("ASIO: Focusrite USB ASIO")
    int inputs = 0, outputs = 0; // known once it has been opened (loading a driver just to count is slow and some object)
};

// The drivers installed, from the registry. Never loads one.
std::vector<AsioDriverInfo> asioDrivers();

class AsioStream {
public:
    // Called on the driver's own thread each buffer: input and output interleaved, as the engine renders them.
    using Callback = void (*)(void* user, const float* input, int input_channels, float* output, int output_channels, int frames);

    AsioStream() = default;
    ~AsioStream();  // stops the driver and lets it go
    AsioStream(const AsioStream&) = delete;
    AsioStream& operator=(const AsioStream&) = delete;

    // Loads the driver named in the device lists and settles its buffer size (the nearest it allows to the one asked
    // for) at the rate it is running at. Nothing runs until start().
    bool open(const std::string& name, int buffer_size, bool with_input, std::string* error);
    bool start(Callback callback, void* user, std::string* error);

    int sampleRate() const { return rate_; }
    int bufferSize() const { return buffer_; }
    int inputs() const { return int(inputs_.size()); }
    int outputs() const { return int(outputs_.size()); }
    int inputLatency() const { return input_latency_; }   // frames, as the driver reports them (its buffer included)
    int outputLatency() const { return output_latency_; }
    // The driver asked to be reopened: its buffer size or rate was changed in its own control panel, or it lost sync.
    bool resetWanted() const;

private:
    struct Channel {
        void* buffers[2] = {};
        long type = 0;
    };
    void close();
    void bufferSwitch(long index);
    friend struct AsioCallbacks;

    void* driver_ = nullptr;  // IASIO*
    bool buffers_ok_ = false, running_ = false, com_ok_ = false;
    bool output_ready_ = false;  // the driver wants to be told when the outputs are filled
    int rate_ = 0, buffer_ = 0, input_latency_ = 0, output_latency_ = 0;
    std::vector<Channel> inputs_, outputs_;
    std::vector<float> in_, out_;  // interleaved, a buffer's worth
    Callback callback_ = nullptr;
    void* user_ = nullptr;
};

}  // namespace sr
