#pragma once

// Playing together: the sound of a player's live inputs (a Speaker, a guitar into an amp) as it leaves the instrument,
// after its pedals, amp and inserts, sent to the other players' computers, which place it in the room as they hear
// it. Compressed with Opus (48 kHz, frames of 5 ms, 128 kb/s each, which is plain to the ear on a guitar or a voice),
// over UDP on a port of its own beside the session's, by way of the host, which passes each player's sounds on to the
// others. Each sound received is held back just long enough to ride out the network's unevenness (a few milliseconds on
// a local network, more over the internet), the hold following how uneven it has lately been, and played back a touch
// faster or slower (0.2 % at most) to keep it there, since two sound cards' clocks never quite agree. A frame that
// doesn't come is made up by Opus from the ones before, as well as it can be.
//
// Three threads: the audio thread hands each block of a sound to send to the network thread, and takes each block of
// a sound received from it, neither waiting on the other (lock-free rings); the network thread sends and receives;
// the game thread starts and stops it and says which sounds go where.

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct OpusEncoder;
struct OpusDecoder;

namespace sr {

// Samples from one thread to another, neither waiting (a single producer and a single consumer).
class FloatRing {
public:
    explicit FloatRing(size_t capacity_pow2) : buf_(capacity_pow2, 0.0f), mask_(capacity_pow2 - 1) {}
    size_t write(const float* in, size_t n);  // as many as there is room for
    size_t available() const { return head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_relaxed); }
    float at(size_t i) const { return buf_[(tail_.load(std::memory_order_relaxed) + i) & mask_]; }  // the i-th unread
    void skip(size_t n) { tail_.store(tail_.load(std::memory_order_relaxed) + n, std::memory_order_release); }
    void reset() { tail_.store(head_.load(std::memory_order_acquire), std::memory_order_release); }  // (consumer)

private:
    std::vector<float> buf_;
    size_t mask_;
    alignas(64) std::atomic<size_t> head_{0};
    alignas(64) std::atomic<size_t> tail_{0};
};

class NetAudio {
public:
    static constexpr int kRate = 48000;     // what goes over the network, whatever each computer runs at
    static constexpr int kFrame = 240;      // 5 ms
    static constexpr int kBitrate = 128000;
    static constexpr int kMaxSending = 8;
    static constexpr int kMaxReceiving = 32;
    static constexpr int kLeastHold = 240;  // the least held back (5 ms), and the most (60 ms)
    static constexpr int kMostHold = 2880;

    NetAudio();
    ~NetAudio();
    NetAudio(const NetAudio&) = delete;
    NetAudio& operator=(const NetAudio&) = delete;

    // Begins. As the host: on `port`, on every network (`address` "*") or `address`'s alone ("127.0.0.1": this
    // computer). As another player, `me`: sending to the host at `address`:`port`. False, with why, if it couldn't.
    bool start(bool host, const std::string& address, int port, uint16_t me, std::string* error);
    void stop();
    bool running() const { return running_.load(std::memory_order_acquire); }
    // (The host) the players in the session, by id: only theirs are taken in, and passed on.
    void setPlayers(const std::vector<uint16_t>& ids);
    // A packet of anyone's from this socket, to `address` (as numbers) and `port`: meeting through a session server
    // (session_server.h), which must see where it comes from, and the host's sending to a player joining, so that its
    // router lets theirs in. False if it isn't running, or the address isn't one.
    bool sendDatagram(const std::string& address, int port, const uint8_t* data, size_t size);

    // What goes where (the game thread). A sound sent is numbered (1 to 255) by the player sending it; a sound
    // received is known by its sender and number. Each gives a slot (or -1, all in use), for the audio thread.
    int openSend(uint8_t number, double engine_rate);
    void closeSend(int slot);
    int openReceive(uint16_t player, uint8_t number, double engine_rate);
    void closeReceive(int slot);

    // The audio thread: a block of a sound to send; a block of a sound received (silent until enough has come in).
    void capture(int slot, const float* in, int n);
    void playout(int slot, float* out, int n);

    struct Stats {
        uint64_t frames = 0;  // sent, or received
        uint64_t lost = 0;    // never came (made up)
        uint64_t late = 0;    // came after their turn (let go)
        float held_ms = 0.0f;  // how much is held back just now
        float hold_ms = 0.0f;  // and how much it aims to hold
    };
    Stats sendStats(int slot) const;
    Stats receiveStats(int slot) const;

private:
    struct Send {
        std::atomic<bool> active{false};
        std::atomic<int64_t> closed_ms{-1000000};
        uint8_t number = 0;
        uint16_t seq = 0;
        double step = 1.0;  // the engine's samples per 48 kHz sample
        double frac = 0.0;
        FloatRing ring{8192};
        OpusEncoder* encoder = nullptr;
        std::atomic<uint64_t> frames{0};
    };
    struct Receive {
        std::atomic<bool> active{false};
        std::atomic<int64_t> closed_ms{-1000000};
        uint16_t player = 0;
        uint8_t number = 0;
        double step = 1.0;  // 48 kHz samples per engine sample
        OpusDecoder* decoder = nullptr;
        FloatRing ring{16384};
        // The network thread's
        bool started = false;
        uint16_t next = 0;
        int64_t last_us = 0;
        float jitter_us = 0.0f;
        std::atomic<int> hold{kLeastHold * 2};
        std::atomic<uint64_t> frames{0}, lost{0}, late{0};
        // The audio thread's
        bool waiting = true;  // filling up again (at first, or having run dry)
        double frac = 0.0;
        float fill_error = 0.0f;  // smoothed
        std::atomic<int> held{0};
    };

    void run();
    void receivePackets();
    void sendFrames();
    void decodeInto(Receive& r, uint16_t seq, const uint8_t* data, int size);
    void sendTo(const void* to, const uint8_t* data, int size);
    static int64_t nowMs();

    std::array<Send, kMaxSending> sends_;
    std::array<Receive, kMaxReceiving> receives_;
    std::atomic<bool> running_{false};
    std::thread thread_;
    bool host_ = false;
    uint16_t me_ = 0;
    intptr_t socket_ = -1;
    std::vector<uint8_t> host_address_;  // (another player's) where the host is: a sockaddr_in
    std::mutex players_mutex_;
    std::vector<uint16_t> players_;      // (the host's) who is in the session
    std::vector<std::pair<uint16_t, std::vector<uint8_t>>> addresses_;  // (the host's) where each player sends from
    int64_t last_hello_ms_ = 0;  // (another player's: to the host every half second; the host's, to each player every second)
};

}  // namespace sr
