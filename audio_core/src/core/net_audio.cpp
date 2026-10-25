// See net_audio.h.

#include "net_audio.h"

#include <opus.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#include "interpolation.h"

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <timeapi.h>
using socklen_t = int;
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#ifdef _WIN32
#define SOCKET_CAST(s) SOCKET(s)
#else
#define SOCKET_CAST(s) int(s)
#endif

namespace sr {

namespace {

// A packet: "SR", what it is (1 a frame of sound, 2 a hello: where a player sends from, for the host), who sent it,
// which of their sounds, its place in that sound's order, then (a frame) what Opus made of it.
constexpr uint8_t kMagic0 = 'S', kMagic1 = 'R', kSound = 1, kHello = 2;
constexpr int kHeader = 8;
constexpr int kMostPacket = 1500;

void putU16(uint8_t* at, uint16_t v) {
    at[0] = uint8_t(v & 0xFF);
    at[1] = uint8_t(v >> 8);
}
uint16_t getU16(const uint8_t* at) { return uint16_t(at[0] | (at[1] << 8)); }

bool sameAddress(const sockaddr_in& a, const sockaddr_in& b) { return a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port; }

void closeSocket(intptr_t s) {
#ifdef _WIN32
    closesocket(SOCKET(s));
#else
    close(int(s));
#endif
}

// Reading a ring between its samples, `step` of them for each sample read: false (and nothing taken) if it hasn't
// enough. The sinc reads the 16 samples about where it reads (7 before it, 8 after), so 17 must be there.
bool readBetween(FloatRing& ring, double& frac, double step, float& out) {
    if (ring.available() < size_t(Sinc16::kTaps + 1)) return false;
    float w[Sinc16::kTaps];
    Sinc16::weights(float(frac), w);
    float sum = 0.0f;
    for (int k = 0; k < Sinc16::kTaps; ++k) sum += w[k] * ring.at(size_t(k));
    out = sum;
    frac += step;
    const double whole = std::floor(frac);
    if (whole > 0.0) {
        ring.skip(size_t(whole));
        frac -= whole;
    }
    return true;
}

}  // namespace

size_t FloatRing::write(const float* in, size_t n) {
    const size_t head = head_.load(std::memory_order_relaxed);
    const size_t room = buf_.size() - (head - tail_.load(std::memory_order_acquire));
    const size_t take = std::min(n, room);
    for (size_t i = 0; i < take; ++i) buf_[(head + i) & mask_] = in[i];
    head_.store(head + take, std::memory_order_release);
    return take;
}

NetAudio::NetAudio() {
    Sinc16::prepare();
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    int error = 0;
    for (auto& s : sends_) {
        s.encoder = opus_encoder_create(kRate, 1, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &error);
        if (s.encoder) {
            opus_encoder_ctl(s.encoder, OPUS_SET_BITRATE(kBitrate));
            opus_encoder_ctl(s.encoder, OPUS_SET_COMPLEXITY(5));
        }
    }
    for (auto& r : receives_) r.decoder = opus_decoder_create(kRate, 1, &error);
}

NetAudio::~NetAudio() {
    stop();
    for (auto& s : sends_)
        if (s.encoder) opus_encoder_destroy(s.encoder);
    for (auto& r : receives_)
        if (r.decoder) opus_decoder_destroy(r.decoder);
#ifdef _WIN32
    WSACleanup();
#endif
}

int64_t NetAudio::nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

bool NetAudio::start(bool host, const std::string& address, int port, uint16_t me, std::string* error) {
    stop();
    host_ = host;
    me_ = me;
    const intptr_t s = intptr_t(socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP));
#ifdef _WIN32
    if (SOCKET(s) == INVALID_SOCKET) {
#else
    if (s < 0) {
#endif
        if (error) *error = "no network socket could be made";
        return false;
    }
    sockaddr_in bound{};
    bound.sin_family = AF_INET;
    bound.sin_port = htons(uint16_t(host ? port : 0));
    bound.sin_addr.s_addr = htonl(INADDR_ANY);
    if (host && address != "*" && !address.empty()) inet_pton(AF_INET, address.c_str(), &bound.sin_addr);
    if (bind(SOCKET_CAST(s), reinterpret_cast<sockaddr*>(&bound), sizeof(bound)) != 0) {
        closeSocket(s);
        if (error) *error = "port " + std::to_string(port) + " is in use";
        return false;
    }
#ifdef _WIN32
    u_long nonblocking = 1;
    ioctlsocket(SOCKET(s), FIONBIO, &nonblocking);
    BOOL reset = FALSE;  // (a packet that found nobody there isn't to stop the next being read)
    DWORD returned = 0;
    WSAIoctl(SOCKET(s), _WSAIOW(IOC_VENDOR, 12), &reset, sizeof(reset), nullptr, 0, &returned, nullptr, nullptr);  // SIO_UDP_CONNRESET
#else
    fcntl(int(s), F_SETFL, fcntl(int(s), F_GETFL, 0) | O_NONBLOCK);
#endif
    if (!host) {  // where the host is
        addrinfo hints{}, *found = nullptr;
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_DGRAM;
        if (getaddrinfo(address.c_str(), std::to_string(port).c_str(), &hints, &found) != 0 || !found) {
            closeSocket(s);
            if (error) *error = address + " couldn't be found";
            return false;
        }
        host_address_.assign(reinterpret_cast<uint8_t*>(found->ai_addr), reinterpret_cast<uint8_t*>(found->ai_addr) + sizeof(sockaddr_in));
        freeaddrinfo(found);
    }
    socket_ = s;
    addresses_.clear();
    last_hello_ms_ = 0;
#ifdef _WIN32
    timeBeginPeriod(1);  // (Windows' timer ticks every 15.6 ms unless asked: the frames would go out in bursts)
#endif
    running_.store(true, std::memory_order_release);
    thread_ = std::thread([this] { run(); });
    return true;
}

void NetAudio::stop() {
    if (!running_.exchange(false)) return;
    if (thread_.joinable()) thread_.join();
    closeSocket(socket_);
    socket_ = -1;
#ifdef _WIN32
    timeEndPeriod(1);
#endif
    const int64_t now = nowMs();
    for (auto& s : sends_)
        if (s.active.exchange(false)) s.closed_ms.store(now);
    for (auto& r : receives_)
        if (r.active.exchange(false)) r.closed_ms.store(now);
}

void NetAudio::setPlayers(const std::vector<uint16_t>& ids) {
    std::lock_guard<std::mutex> lock(players_mutex_);
    players_ = ids;
}

// A slot is used again only once it has been closed a second: the audio thread may still have been in it.
int NetAudio::openSend(uint8_t number, double engine_rate) {
    const int64_t now = nowMs();
    for (int i = 0; i < kMaxSending; ++i) {
        Send& s = sends_[size_t(i)];
        if (s.active.load(std::memory_order_acquire) || now - s.closed_ms.load() < 1000 || !s.encoder) continue;
        s.number = number;
        s.seq = 0;
        s.step = engine_rate / double(kRate);
        s.frac = 0.0;
        s.ring.reset();
        s.frames.store(0);
        opus_encoder_ctl(s.encoder, OPUS_RESET_STATE);
        s.active.store(true, std::memory_order_release);
        return i;
    }
    return -1;
}

void NetAudio::closeSend(int slot) {
    if (slot < 0 || slot >= kMaxSending) return;
    if (sends_[size_t(slot)].active.exchange(false)) sends_[size_t(slot)].closed_ms.store(nowMs());
}

int NetAudio::openReceive(uint16_t player, uint8_t number, double engine_rate) {
    const int64_t now = nowMs();
    for (int i = 0; i < kMaxReceiving; ++i) {
        Receive& r = receives_[size_t(i)];
        if (r.active.load(std::memory_order_acquire) || now - r.closed_ms.load() < 1000 || !r.decoder) continue;
        r.player = player;
        r.number = number;
        r.step = double(kRate) / engine_rate;
        r.started = false;
        r.jitter_us = 0.0f;
        r.hold.store(kLeastHold * 2);
        r.frames.store(0);
        r.lost.store(0);
        r.late.store(0);
        r.waiting = true;
        r.frac = 0.0;
        r.fill_error = 0.0f;
        r.ring.reset();
        opus_decoder_ctl(r.decoder, OPUS_RESET_STATE);
        r.active.store(true, std::memory_order_release);
        return i;
    }
    return -1;
}

void NetAudio::closeReceive(int slot) {
    if (slot < 0 || slot >= kMaxReceiving) return;
    if (receives_[size_t(slot)].active.exchange(false)) receives_[size_t(slot)].closed_ms.store(nowMs());
}

void NetAudio::capture(int slot, const float* in, int n) {
    if (slot < 0 || slot >= kMaxSending) return;
    Send& s = sends_[size_t(slot)];
    if (s.active.load(std::memory_order_acquire)) s.ring.write(in, size_t(n));
}

// What it plays out is read from what has come in, between its samples: a touch faster while more is held than it aims
// to hold, a touch slower while less (0.2 % at most, the difference smoothed over about a second, so that nothing
// wavers), and silence while it fills up (at first, or having run dry), until it holds what it aims to.
void NetAudio::playout(int slot, float* out, int n) {
    std::fill(out, out + n, 0.0f);
    if (slot < 0 || slot >= kMaxReceiving) return;
    Receive& r = receives_[size_t(slot)];
    if (!r.active.load(std::memory_order_acquire)) return;
    const int hold = r.hold.load(std::memory_order_relaxed);
    size_t have = r.ring.available();
    if (r.waiting) {
        if (have < size_t(hold + Sinc16::kTaps)) {
            r.held.store(int(have), std::memory_order_relaxed);
            return;
        }
        r.waiting = false;
    }
    if (have > size_t(hold) * 4 + size_t(kFrame) * 4) {  // (a burst: too much at once to catch up on gently)
        r.ring.skip(have - size_t(hold));
        have = r.ring.available();
    }
    const float error = std::clamp((float(have) - float(hold)) / float(hold), -1.0f, 1.0f);
    r.fill_error += (error - r.fill_error) * std::min(1.0f, float(n) / 48000.0f);
    const double step = r.step * (1.0 + 0.002 * double(r.fill_error));
    for (int i = 0; i < n; ++i) {
        if (!readBetween(r.ring, r.frac, step, out[i])) {
            r.waiting = true;  // run dry: fill up again
            break;
        }
    }
    r.held.store(int(r.ring.available()), std::memory_order_relaxed);
}

NetAudio::Stats NetAudio::sendStats(int slot) const {
    Stats st;
    if (slot >= 0 && slot < kMaxSending) st.frames = sends_[size_t(slot)].frames.load();
    return st;
}

NetAudio::Stats NetAudio::receiveStats(int slot) const {
    Stats st;
    if (slot < 0 || slot >= kMaxReceiving) return st;
    const Receive& r = receives_[size_t(slot)];
    st.frames = r.frames.load();
    st.lost = r.lost.load();
    st.late = r.late.load();
    st.held_ms = float(r.held.load()) * 1000.0f / float(kRate);
    st.hold_ms = float(r.hold.load()) * 1000.0f / float(kRate);
    return st;
}

// ── The network thread ───────────────────────────────────────────────────────────────────────────────────────

void NetAudio::run() {
    while (running_.load(std::memory_order_acquire)) {
#ifdef _WIN32
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(SOCKET(socket_), &readable);
        timeval wait{0, 1000};
        select(0, &readable, nullptr, nullptr, &wait);
#else
        pollfd waiting{int(socket_), POLLIN, 0};
        poll(&waiting, 1, 1);
#endif
        receivePackets();
        sendFrames();
        const int64_t now = nowMs();
        if (!host_ && now - last_hello_ms_ >= 500) {  // (another player: where they send from, for the host)
            last_hello_ms_ = now;
            uint8_t hello[kHeader] = {kMagic0, kMagic1, kHello, 0, 0, 0, 0, 0};
            putU16(hello + 3, me_);
            sendTo(host_address_.data(), hello, kHeader);
        }
    }
}

void NetAudio::sendTo(const void* to, const uint8_t* data, int size) {
    sendto(SOCKET_CAST(socket_), reinterpret_cast<const char*>(data), size, 0, static_cast<const sockaddr*>(to), sizeof(sockaddr_in));
}

void NetAudio::receivePackets() {
    uint8_t packet[kMostPacket];
    while (true) {
        sockaddr_in from{};
        socklen_t from_size = sizeof(from);
        const int size = int(recvfrom(SOCKET_CAST(socket_), reinterpret_cast<char*>(packet), kMostPacket, 0, reinterpret_cast<sockaddr*>(&from), &from_size));
        if (size < kHeader) {
            if (size < 0) return;  // (nothing more for now)
            continue;
        }
        if (packet[0] != kMagic0 || packet[1] != kMagic1) continue;
        const uint16_t sender = getU16(packet + 3);
        if (host_) {  // only the session's players; and where each sends from, to pass the others' sounds to
            std::lock_guard<std::mutex> lock(players_mutex_);
            if (sender == me_ || std::find(players_.begin(), players_.end(), sender) == players_.end()) continue;
            auto known = std::find_if(addresses_.begin(), addresses_.end(), [&](const auto& a) { return a.first == sender; });
            const std::vector<uint8_t> address(reinterpret_cast<uint8_t*>(&from), reinterpret_cast<uint8_t*>(&from) + sizeof(from));
            if (known == addresses_.end()) addresses_.push_back({sender, address});
            else known->second = address;
            if (packet[2] == kSound)
                for (const auto& a : addresses_)
                    if (a.first != sender) sendTo(a.second.data(), packet, size);
        } else {  // only the host's
            if (host_address_.size() != sizeof(sockaddr_in) || !sameAddress(from, *reinterpret_cast<const sockaddr_in*>(host_address_.data()))) continue;
        }
        if (packet[2] != kSound) continue;
        const uint8_t number = packet[5];
        const uint16_t seq = getU16(packet + 6);
        for (auto& r : receives_)
            if (r.active.load(std::memory_order_acquire) && r.player == sender && r.number == number) decodeInto(r, seq, packet + kHeader, size - kHeader);
    }
}

// A frame received, decoded into its sound's ring in order: one that comes after its turn is let go (but one far behind
// is its sound started again); those that never came before it are made up (four at most: after a longer gap it
// starts again from this one). How unevenly frames
// come sets how much is held back: three times their recent unevenness, and a frame, within 5 to 60 ms.
void NetAudio::decodeInto(Receive& r, uint16_t seq, const uint8_t* data, int size) {
    float pcm[kFrame];
    if (!r.started) {
        r.started = true;
        r.next = seq;
    }
    int16_t ahead = int16_t(uint16_t(seq - r.next));
    if (ahead < -64) {  // (started again by its sender, from the first)
        r.next = seq;
        ahead = 0;
    }
    if (ahead < 0) {
        r.late.fetch_add(1);
        return;
    }
    if (ahead > 0) {
        r.lost.fetch_add(uint64_t(ahead));
        for (int k = 0; k < std::min<int>(ahead, 4); ++k) {
            const int made = opus_decode_float(r.decoder, nullptr, 0, pcm, kFrame, 0);
            if (made > 0) r.ring.write(pcm, size_t(made));
        }
    }
    const int got = opus_decode_float(r.decoder, data, size, pcm, kFrame, 0);
    if (got > 0) r.ring.write(pcm, size_t(got));
    r.next = uint16_t(seq + 1);
    r.frames.fetch_add(1);
    const int64_t now = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    if (r.last_us != 0) {
        const float off = std::fabs(float(now - r.last_us) - 5000.0f * float(ahead + 1));
        r.jitter_us += (off - r.jitter_us) * (off > r.jitter_us ? 0.1f : 0.002f);  // (quick to grow, slow to shrink)
    }
    r.last_us = now;
    const int hold = int(3.0f * r.jitter_us * 1e-6f * float(kRate)) + kFrame;
    r.hold.store(std::clamp(hold, kLeastHold, kMostHold), std::memory_order_relaxed);
}

// Each sound's frames as they fill: read at 48 kHz from what the audio thread wrote at its own rate, coded, sent (to
// the host; or, from the host, to every player).
void NetAudio::sendFrames() {
    float frame[kFrame];
    uint8_t packet[kMostPacket];
    for (auto& s : sends_) {
        if (!s.active.load(std::memory_order_acquire)) continue;
        while (s.ring.available() >= size_t(double(kFrame) * s.step) + size_t(Sinc16::kTaps) + 1) {
            bool whole = true;
            for (int i = 0; i < kFrame && whole; ++i) whole = readBetween(s.ring, s.frac, s.step, frame[i]);
            if (!whole) break;
            const int coded = opus_encode_float(s.encoder, frame, kFrame, packet + kHeader, kMostPacket - kHeader);
            if (coded <= 0) continue;
            packet[0] = kMagic0;
            packet[1] = kMagic1;
            packet[2] = kSound;
            putU16(packet + 3, me_);
            packet[5] = s.number;
            putU16(packet + 6, s.seq++);
            if (host_) {
                std::lock_guard<std::mutex> lock(players_mutex_);
                for (const auto& a : addresses_) sendTo(a.second.data(), packet, kHeader + coded);
            } else {
                sendTo(host_address_.data(), packet, kHeader + coded);
            }
            s.frames.fetch_add(1);
        }
    }
}

}  // namespace sr
