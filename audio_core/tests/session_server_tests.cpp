// The session server's checks (src/server/session_server.h), on this computer alone: a server started here, and plain
// sockets standing in for a host's and a joining player's (their requests, and their session's own sockets).
// Run: audio_core/build/session_server_tests

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "session_server.h"

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
using socklen_t = int;
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace {

int failures = 0;

void check(bool ok, const std::string& what, const std::string& detail) {
    std::printf("  [%s] %s  (%s)\n", ok ? "pass" : "FAIL", what.c_str(), detail.c_str());
    if (!ok) ++failures;
}

// A UDP socket on 127.0.0.1, as a player's computer has.
struct Udp {
#ifdef _WIN32
    SOCKET s = INVALID_SOCKET;
#else
    int s = -1;
#endif
    int port = 0;

    Udp() {
        s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        sockaddr_in at{};
        at.sin_family = AF_INET;
        at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        bind(s, reinterpret_cast<sockaddr*>(&at), sizeof(at));
        socklen_t size = sizeof(at);
        getsockname(s, reinterpret_cast<sockaddr*>(&at), &size);
        port = ntohs(at.sin_port);
#ifdef _WIN32
        u_long nonblocking = 1;
        ioctlsocket(s, FIONBIO, &nonblocking);
#else
        fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#endif
    }
    ~Udp() {
#ifdef _WIN32
        closesocket(s);
#else
        close(s);
#endif
    }

    void send(int to, const std::string& data) const {
        sockaddr_in at{};
        at.sin_family = AF_INET;
        at.sin_port = htons(uint16_t(to));
        at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        sendto(s, data.data(), int(data.size()), 0, reinterpret_cast<sockaddr*>(&at), sizeof(at));
    }
    // A request: padded to the least the server reads.
    void ask(int to, const std::string& text) const { send(to, text + std::string(text.size() < 128 ? 128 - text.size() : 0, ' ')); }

    // What comes within `ms` (the first packet; "" if none), and the port it came from.
    std::string receive(int ms = 1000, int* from_port = nullptr) const {
        const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
        char data[2048];
        while (std::chrono::steady_clock::now() < until) {
            sockaddr_in from{};
            socklen_t size = sizeof(from);
            const int got = int(recvfrom(s, data, int(sizeof(data)), 0, reinterpret_cast<sockaddr*>(&from), &size));
            if (got >= 0) {
                if (from_port) *from_port = ntohs(from.sin_port);
                return std::string(data, size_t(got));
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        return "";
    }
    // The first that begins with `start`, within `ms` (others let go).
    std::string receiveStarting(const std::string& start, int ms = 1000) const {
        const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
        while (std::chrono::steady_clock::now() < until) {
            const std::string got = receive(50);
            if (got.compare(0, start.size(), start) == 0) return got;
        }
        return "";
    }
};

std::vector<std::string> words(const std::string& text) {
    std::vector<std::string> out;
    size_t at = 0;
    while (at < text.size()) {
        const size_t end = text.find(' ', at);
        if (end != at) out.push_back(text.substr(at, end == std::string::npos ? std::string::npos : end - at));
        if (end == std::string::npos) break;
        at = end + 1;
    }
    return out;
}

void settle() { std::this_thread::sleep_for(std::chrono::milliseconds(150)); }

}  // namespace

int main() {
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    std::printf("SoundRoom's session server: checks\n\n");
    sr::SessionServer server;
    sr::SessionServer::Options options;
    options.bind = "127.0.0.1";
    options.port = 0;
    options.log = false;
    options.most_per_address = 2;
    std::string error;
    const bool started = server.start(options, &error);
    check(started && server.port() > 0, "the server starts, on a port of its own", error + std::to_string(server.port()));
    if (!started) return 1;
    const int at = server.port();

    // A host asks for a session: given a code, and a token of its own (the same again if it asks again, the answer lost).
    Udp host_control, host_game, host_sound;
    host_control.send(at, "SM1 host n1 47130 47131 192.168.1.20");
    const std::string ignored = host_control.receive(300);
    host_control.ask(at, "SM1 host n1 47130 47131 192.168.1.20");
    const std::vector<std::string> hosted = words(host_control.receive());
    host_control.ask(at, "SM1 host n1 47130 47131 192.168.1.20");
    const std::vector<std::string> again = words(host_control.receive());
    check(ignored.empty() && hosted.size() == 5 && hosted[1] == "hosted" && hosted[2] == "n1" && hosted[3].size() == 6 && hosted[4].size() == 20 &&
              again.size() == 5 && again[3] == hosted[3] && server.counts().sessions == 1,
          "a host is given a code and a token (a request too short to be one is let go; asked again, the same)",
          hosted.size() == 5 ? hosted[3] : "no answer");
    if (hosted.size() != 5) return 1;
    const std::string code = hosted[3].substr(0, 3) + "-" + hosted[3].substr(3), token = hosted[4];

    // Someone finding it before the host's sockets are known is asked to wait; a code nobody has is unknown.
    Udp guest_control, guest_game, guest_sound;
    guest_control.ask(at, "SM1 find " + code + " g1");
    const std::string waiting = guest_control.receive();
    guest_control.ask(at, "SM1 find ZZZ-ZZZ g0");
    const std::string unknown = guest_control.receive();
    check(waiting == "SM1 wait g1" && unknown == "SM1 unknown g0", "a session not ready yet is to be waited for; a code nobody has, unknown",
          waiting + ", " + unknown);

    // The host's sockets seen; found by its code (as typed, in small letters), where the internet sees them.
    host_game.ask(at, "SM1 at " + token + " game");
    host_sound.ask(at, "SM1 at " + token + " sound");
    settle();
    std::string lower = code;
    for (char& c : lower) c = char(c >= 'A' && c <= 'Z' ? c + 32 : c);
    guest_control.ask(at, "SM1 find " + lower + " g1");
    const std::vector<std::string> found = words(guest_control.receive());
    check(found.size() == 10 && found[1] == "found" && found[2] == "g1" && found[4] == "127.0.0.1" && found[5] == std::to_string(host_game.port) &&
              found[6] == std::to_string(host_sound.port) && found[7] == "192.168.1.20" && found[8] == "47130",
          "the session is found by its code: the host's sockets where the internet sees them (and, the same network's, where it does)",
          found.size() >= 7 ? found[4] + ":" + found[5] + ", " + found[6] : "no answer");
    if (found.size() < 7) return 1;
    const std::string ticket = found[3];

    // The joining player's session sockets seen: the host told where, so that it sends to them (and its router lets
    // their packets in).
    guest_game.ask(at, "SM1 at " + ticket + " game");
    const std::vector<std::string> knock = words(host_control.receiveStarting("SM1 knock"));
    guest_sound.ask(at, "SM1 at " + ticket + " sound");
    const std::vector<std::string> knock_sound = words(host_control.receiveStarting("SM1 knock"));
    check(knock.size() == 6 && knock[2] == ticket && knock[3] == "game" && knock[5] == std::to_string(guest_game.port) && knock_sound.size() == 6 &&
              knock_sound[3] == "sound" && knock_sound[5] == std::to_string(guest_sound.port),
          "the host is told where a joining player's sockets are, to send to them",
          knock.size() == 6 ? knock[4] + ":" + knock[5] : "not told");

    // A relay: two ports, the joining player told them, and the host; its end found by its token; then what each sends
    // is passed to the other, both ways, on both.
    guest_control.ask(at, "SM1 relay " + ticket + " r1");
    const std::vector<std::string> relayed = words(guest_control.receive());
    const std::vector<std::string> told = words(host_control.receiveStarting("SM1 relay"));
    const bool relay_ok = relayed.size() == 5 && relayed[1] == "relayed" && told.size() == 5 && told[3] == relayed[3] && told[4] == relayed[4];
    check(relay_ok && server.counts().relays == 1, "a joining player asking for a relay is given two ports, and the host told them",
          relayed.size() == 5 ? relayed[3] + ", " + relayed[4] : "no answer");
    if (!relay_ok) return 1;
    const int relay_game = std::stoi(relayed[3]), relay_sound = std::stoi(relayed[4]);
    guest_game.send(relay_game, "early");  // (before the host's end is known: let go)
    host_game.ask(relay_game, "SM1 at " + token + " relay");
    host_sound.ask(relay_sound, "SM1 at " + token + " relay");
    settle();
    const std::string early = host_game.receive(200);
    guest_game.send(relay_game, "connect");
    int came_from = 0;
    const std::string to_host = host_game.receive(1000, &came_from);
    host_game.send(came_from, "verify");
    const std::string to_guest = guest_game.receive();
    guest_sound.send(relay_sound, "hello from 2");
    const std::string sound_to_host = host_sound.receive();
    host_sound.send(relay_sound, "a frame");
    const std::string sound_to_guest = guest_sound.receive();
    check(early.empty() && to_host == "connect" && came_from == relay_game && to_guest == "verify" && sound_to_host == "hello from 2" &&
              sound_to_guest == "a frame" && server.counts().relayed >= 4,
          "what each sends to the relay is passed to the other, both ways, on both its ports",
          "the host hears the player from port " + std::to_string(came_from));

    // Someone else (a request that isn't the host's token) isn't taken for the host.
    Udp stranger;
    stranger.ask(relay_game, "SM1 at WRONGTOKEN relay");
    settle();
    guest_game.send(relay_game, "still to the host");
    const std::string still = host_game.receive();
    check(still == "still to the host", "a relay's host end isn't taken over by someone without the session's token", still);

    // Kept alive; a second session from the same address; a third is too many.
    host_control.ask(at, "SM1 alive " + token);
    const std::string alive = host_control.receiveStarting("SM1 alive");
    Udp second, third;
    second.ask(at, "SM1 host n2 1 2");
    const std::vector<std::string> second_hosted = words(second.receive());
    third.ask(at, "SM1 host n3 1 2");
    const std::string busy = third.receive();
    check(alive == "SM1 alive" && second_hosted.size() == 5 && second_hosted[3] != hosted[3] && busy == "SM1 busy n3",
          "a session is kept alive; one address hosts only so many at once", busy);

    // Ended: its relay closed with it; a token nobody has is gone.
    host_control.ask(at, "SM1 end " + token);
    settle();
    guest_game.send(relay_game, "after");
    const std::string after = host_game.receive(300);
    host_control.ask(at, "SM1 alive " + token);
    const std::string gone = host_control.receive();
    const sr::SessionServer::Counts counts = server.counts();
    check(after.empty() && gone == "SM1 gone " + token && counts.sessions == 1 && counts.relays == 0,
          "a session ended is gone, its relay closed with it", std::to_string(counts.sessions) + " session left, " + std::to_string(counts.relays) + " relays");

    server.stop();
#ifdef _WIN32
    WSACleanup();
#endif
    std::printf("\n%s\n", failures ? "SOME CHECKS FAILED" : "All checks passed");
    return failures ? 1 : 0;
}
