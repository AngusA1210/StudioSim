// See session_server.h.

#include "session_server.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <mutex>
#include <random>
#include <vector>

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
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace sr {

namespace {

#ifdef _WIN32
using Socket = SOCKET;
using PollFd = WSAPOLLFD;
const Socket kNoSocket = INVALID_SOCKET;
int pollAll(PollFd* fds, size_t n, int ms) { return WSAPoll(fds, ULONG(n), ms); }
void closeSocket(Socket s) { closesocket(s); }
#else
using Socket = int;
using PollFd = pollfd;
constexpr Socket kNoSocket = -1;
int pollAll(PollFd* fds, size_t n, int ms) { return poll(fds, nfds_t(n), ms); }
void closeSocket(Socket s) { close(s); }
#endif

constexpr size_t kLeast = 128;        // a request's least size (bytes)
constexpr size_t kMostPacket = 2048;  // (ENet's and the sound's are well under this)
constexpr int64_t kSessionLife = 40000;  // ms without being kept alive
constexpr int64_t kRelayLife = 60000;    // ms unused
constexpr int64_t kTicketLife = 600000;
constexpr size_t kMostTickets = 32;      // a session's players joining (the oldest let go)
constexpr int kMostRelaysEach = 16;      // a session's relays
const char kAlphabet[] = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";  // (no O and 0, no I and 1)

int64_t nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

bool same(const sockaddr_in& a, const sockaddr_in& b) { return a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port; }

std::string addressOf(const sockaddr_in& a) {
    char text[INET_ADDRSTRLEN] = {};
    inet_ntop(AF_INET, &a.sin_addr, text, sizeof(text));
    return text;
}

// A UDP socket on `port` (0: any) at `ip` (network order), not waiting when there is nothing to read; and the port it got.
Socket openSocket(uint32_t ip, int port, int* bound_port) {
    const Socket s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == kNoSocket) return kNoSocket;
    sockaddr_in at{};
    at.sin_family = AF_INET;
    at.sin_port = htons(uint16_t(port));
    at.sin_addr.s_addr = ip;
    if (bind(s, reinterpret_cast<sockaddr*>(&at), sizeof(at)) != 0) {
        closeSocket(s);
        return kNoSocket;
    }
    socklen_t size = sizeof(at);
    getsockname(s, reinterpret_cast<sockaddr*>(&at), &size);
    *bound_port = ntohs(at.sin_port);
#ifdef _WIN32
    u_long nonblocking = 1;
    ioctlsocket(s, FIONBIO, &nonblocking);
    BOOL reset = FALSE;  // (a packet that found nobody there isn't to stop the next being read)
    DWORD returned = 0;
    WSAIoctl(s, _WSAIOW(IOC_VENDOR, 12), &reset, sizeof(reset), nullptr, 0, &returned, nullptr, nullptr);  // SIO_UDP_CONNRESET
#else
    fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#endif
    return s;
}

void sendTo(Socket s, const sockaddr_in& to, const char* data, size_t size) {
    sendto(s, data, int(size), 0, reinterpret_cast<const sockaddr*>(&to), sizeof(to));
}

// A request's words (its padding left off).
std::vector<std::string> wordsOf(const char* p, size_t n) {
    std::vector<std::string> words;
    std::string word;
    for (size_t i = 0; i <= n; ++i) {
        const char c = i < n ? p[i] : ' ';
        if (c == ' ' || c == '\0' || c == '\n' || c == '\r' || c == '\t') {
            if (!word.empty()) words.push_back(word);
            word.clear();
            if (words.size() >= 12) break;
        } else if (word.size() < 64) {
            word += c;
        }
    }
    return words;
}

// A code as typed ("k7q-m2d") as it is kept ("K7QM2D").
std::string plainCode(const std::string& code) {
    std::string out;
    for (char c : code)
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) out += char(c >= 'a' && c <= 'z' ? c - 32 : c);
    return out;
}

}  // namespace

struct SessionServer::State {
    struct Ticket {
        std::string id, nonce;
        uint32_t ip = 0;  // where the player joining asked from
        int64_t made = 0;
    };
    struct Session {
        std::string code, token, nonce;
        sockaddr_in control{};          // where the host's requests come from: its notices go there
        sockaddr_in game{}, sound{};    // the host's session sockets, as the internet sees them
        bool game_known = false, sound_known = false;
        int local_game = 0, local_sound = 0;  // and as its own network does
        std::string lan;
        int64_t alive = 0;
        std::vector<Ticket> tickets;
    };
    struct Leg {  // one of a relay's two ports: the session's messages, or the sound
        Socket socket = kNoSocket;
        int port = 0;
        sockaddr_in host{}, guest{};
        bool host_known = false, guest_known = false;
    };
    struct Relay {
        Leg legs[2];
        std::string token, ticket, nonce;
        uint32_t guest_ip = 0;
        int64_t used = 0;
    };

    Options options;
    Socket main = kNoSocket;
    uint32_t bind_ip = 0;
    std::vector<Session> sessions;
    std::vector<Relay> relays;
    std::mt19937_64 random{std::random_device{}()};
    int next_relay_port = 0;
    uint64_t relayed = 0;
    mutable std::mutex counts_mutex;
    Counts counts;

    std::string randomText(size_t n) {
        std::string out;
        for (size_t i = 0; i < n; ++i) out += kAlphabet[random() % (sizeof(kAlphabet) - 1)];
        return out;
    }

    void log(const std::string& text) const {
        if (!options.log) return;
        const std::time_t now = std::time(nullptr);
        char stamp[32] = {};
        std::strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", std::gmtime(&now));
        std::printf("%s  %s\n", stamp, text.c_str());
        std::fflush(stdout);
    }

    void reply(const sockaddr_in& to, const std::string& text) const { sendTo(main, to, text.data(), text.size()); }

    Session* byToken(const std::string& token) {
        for (auto& s : sessions)
            if (s.token == token) return &s;
        return nullptr;
    }
    Session* byCode(const std::string& code) {
        const std::string plain = plainCode(code);
        for (auto& s : sessions)
            if (s.code == plain) return &s;
        return nullptr;
    }
    Session* byTicket(const std::string& ticket, Ticket** found) {
        for (auto& s : sessions)
            for (auto& t : s.tickets)
                if (t.id == ticket) {
                    *found = &t;
                    return &s;
                }
        return nullptr;
    }
    Relay* relayFor(const std::string& ticket) {
        for (auto& r : relays)
            if (r.ticket == ticket) return &r;
        return nullptr;
    }

    static std::string shown(const std::string& code) { return code.substr(0, 3) + "-" + code.substr(3); }

    // A request to the server's own port.
    void onMain(const char* p, size_t n, const sockaddr_in& from) {
        if (n < kLeast) return;
        const std::vector<std::string> w = wordsOf(p, n);
        if (w.size() < 3 || w[0] != "SM1") return;
        const std::string& verb = w[1];
        const int64_t now = nowMs();
        if (verb == "host" && w.size() >= 5) {
            for (auto& s : sessions)
                if (s.nonce == w[2] && s.control.sin_addr.s_addr == from.sin_addr.s_addr) {  // (asked again: the answer lost)
                    s.control = from;
                    reply(from, "SM1 hosted " + s.nonce + " " + s.code + " " + s.token);
                    return;
                }
            const auto from_here = std::count_if(sessions.begin(), sessions.end(), [&](const Session& s) {
                return s.control.sin_addr.s_addr == from.sin_addr.s_addr; });
            if (int(sessions.size()) >= options.most_sessions || int(from_here) >= options.most_per_address) {
                reply(from, "SM1 busy " + w[2]);
                return;
            }
            Session s;
            do s.code = randomText(6); while (byCode(s.code));
            s.token = randomText(20);
            s.nonce = w[2];
            s.control = from;
            s.local_game = std::atoi(w[3].c_str());
            s.local_sound = std::atoi(w[4].c_str());
            if (w.size() >= 6) s.lan = w[5];
            s.alive = now;
            sessions.push_back(s);
            reply(from, "SM1 hosted " + s.nonce + " " + s.code + " " + s.token);
            log("hosted " + shown(s.code) + " from " + addressOf(from));
        } else if (verb == "alive") {
            Session* s = byToken(w[2]);
            if (!s) {
                reply(from, "SM1 gone " + w[2]);
                return;
            }
            s->control = from;
            s->alive = now;
            reply(from, "SM1 alive");
        } else if (verb == "end") {
            for (size_t i = 0; i < sessions.size(); ++i)
                if (sessions[i].token == w[2]) {
                    endSession(i, "ended");
                    break;
                }
        } else if (verb == "at" && w.size() >= 4) {
            const bool game = w[3] == "game";
            if (!game && w[3] != "sound") return;
            if (Session* s = byToken(w[2])) {  // (the host's)
                (game ? s->game : s->sound) = from;
                (game ? s->game_known : s->sound_known) = true;
                return;
            }
            Ticket* t = nullptr;
            if (Session* s = byTicket(w[2], &t))  // (a player joining's: the host is to send to it)
                reply(s->control, "SM1 knock " + t->id + " " + w[3] + " " + addressOf(from) + " " + std::to_string(ntohs(from.sin_port)));
        } else if (verb == "find" && w.size() >= 4) {
            Session* s = byCode(w[2]);
            if (!s) {
                reply(from, "SM1 unknown " + w[3]);
                return;
            }
            if (!s->game_known || !s->sound_known) {
                reply(from, "SM1 wait " + w[3]);
                return;
            }
            Ticket* ticket = nullptr;
            for (auto& t : s->tickets)
                if (t.nonce == w[3] && t.ip == from.sin_addr.s_addr) ticket = &t;
            if (!ticket) {
                if (s->tickets.size() >= kMostTickets) s->tickets.erase(s->tickets.begin());
                Ticket t;
                t.id = randomText(12);
                t.nonce = w[3];
                t.ip = from.sin_addr.s_addr;
                t.made = now;
                s->tickets.push_back(t);
                ticket = &s->tickets.back();
                log("found " + shown(s->code) + " from " + addressOf(from));
            }
            std::string found = "SM1 found " + w[3] + " " + ticket->id + " " + addressOf(s->game) + " " + std::to_string(ntohs(s->game.sin_port)) +
                " " + std::to_string(ntohs(s->sound.sin_port));
            if (from.sin_addr.s_addr == s->game.sin_addr.s_addr && !s->lan.empty())  // (on the host's own network: its address there)
                found += " " + s->lan + " " + std::to_string(s->local_game) + " " + std::to_string(s->local_sound);
            reply(from, found);
        } else if (verb == "relay" && w.size() >= 4) {
            Ticket* t = nullptr;
            Session* s = byTicket(w[2], &t);
            if (!s || t->ip != from.sin_addr.s_addr) return;
            Relay* r = relayFor(t->id);
            if (!r) {
                const auto theirs = std::count_if(relays.begin(), relays.end(), [&](const Relay& each) { return each.token == s->token; });
                Relay made;
                made.token = s->token;
                made.ticket = t->id;
                made.guest_ip = t->ip;
                made.used = now;
                if (int(relays.size()) >= options.most_relays || int(theirs) >= kMostRelaysEach || !openRelay(made)) {
                    reply(from, "SM1 busy " + w[3]);
                    return;
                }
                relays.push_back(made);
                r = &relays.back();
                log("relaying " + shown(s->code) + " for " + addressOf(from) + " on ports " + std::to_string(r->legs[0].port) + " and " +
                    std::to_string(r->legs[1].port));
            }
            const std::string ports = std::to_string(r->legs[0].port) + " " + std::to_string(r->legs[1].port);
            reply(from, "SM1 relayed " + w[3] + " " + ports);
            reply(s->control, "SM1 relay " + t->id + " " + ports);
        }
    }

    // A packet to one of a relay's ports: the host's end of it found (by its token), or passed on between the two.
    void onRelay(Relay& r, int which, const char* p, size_t n, const sockaddr_in& from) {
        Leg& leg = r.legs[which];
        if (n >= 7 && std::memcmp(p, "SM1 at ", 7) == 0) {
            const std::vector<std::string> w = wordsOf(p, n);
            if (w.size() >= 3 && w[2] == r.token) {
                leg.host = from;
                leg.host_known = true;
            }
            return;
        }
        if (leg.host_known && same(from, leg.host)) {
            if (!leg.guest_known) return;
            sendTo(leg.socket, leg.guest, p, n);
        } else if (from.sin_addr.s_addr == r.guest_ip) {
            leg.guest = from;
            leg.guest_known = true;
            if (!leg.host_known) return;
            sendTo(leg.socket, leg.host, p, n);
        } else {
            return;
        }
        r.used = nowMs();
        ++relayed;
    }

    bool openRelay(Relay& r) {
        for (Leg& leg : r.legs) {
            if (options.relay_from > 0 && options.relay_to >= options.relay_from) {  // (the next free ports in the range)
                const int span = options.relay_to - options.relay_from + 1;
                for (int tries = 0; tries < span && leg.socket == kNoSocket; ++tries) {
                    const int port = options.relay_from + (next_relay_port++ % span);
                    leg.socket = openSocket(bind_ip, port, &leg.port);
                }
            } else {
                leg.socket = openSocket(bind_ip, 0, &leg.port);
            }
            if (leg.socket == kNoSocket) {
                closeRelay(r);
                return false;
            }
        }
        return true;
    }

    static void closeRelay(Relay& r) {
        for (Leg& leg : r.legs)
            if (leg.socket != kNoSocket) {
                closeSocket(leg.socket);
                leg.socket = kNoSocket;
            }
    }

    // (Its relays closed, and let go of once the sockets read just now are done with: see compact.)
    void endSession(size_t index, const char* why) {
        const std::string token = sessions[index].token;
        log(std::string(why) + " " + shown(sessions[index].code));
        for (auto& r : relays)
            if (r.token == token) closeRelay(r);
        sessions.erase(sessions.begin() + std::ptrdiff_t(index));
    }

    void compact() {
        relays.erase(std::remove_if(relays.begin(), relays.end(), [](const Relay& r) { return r.legs[0].socket == kNoSocket; }), relays.end());
    }

    void expire(int64_t now) {
        for (size_t i = sessions.size(); i-- > 0;)
            if (now - sessions[i].alive > kSessionLife) endSession(i, "lost");
        for (auto& s : sessions)
            s.tickets.erase(std::remove_if(s.tickets.begin(), s.tickets.end(), [&](const Ticket& t) {
                return now - t.made > kTicketLife && !relayFor(t.id); }), s.tickets.end());
        for (auto& r : relays)
            if (now - r.used > kRelayLife) closeRelay(r);
    }
};

SessionServer::SessionServer() : state_(std::make_unique<State>()) {
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
}

SessionServer::~SessionServer() {
    stop();
#ifdef _WIN32
    WSACleanup();
#endif
}

bool SessionServer::start(const Options& options, std::string* error) {
    stop();
    State& st = *state_;
    st.options = options;
    in_addr ip{};
    if (inet_pton(AF_INET, options.bind.c_str(), &ip) != 1) {
        if (error) *error = options.bind + " isn't an address of this machine";
        return false;
    }
    st.bind_ip = ip.s_addr;
    st.main = openSocket(st.bind_ip, options.port, &port_);
    if (st.main == kNoSocket) {
        if (error) *error = "port " + std::to_string(options.port) + " couldn't be opened (is it in use?)";
        return false;
    }
    running_.store(true, std::memory_order_release);
    thread_ = std::thread([this] { run(); });
    return true;
}

void SessionServer::stop() {
    if (!running_.exchange(false)) return;
    if (thread_.joinable()) thread_.join();
    State& st = *state_;
    for (auto& r : st.relays) State::closeRelay(r);
    st.relays.clear();
    st.sessions.clear();
    closeSocket(st.main);
    st.main = kNoSocket;
}

SessionServer::Counts SessionServer::counts() const {
    std::lock_guard<std::mutex> lock(state_->counts_mutex);
    return state_->counts;
}

void SessionServer::run() {
    State& st = *state_;
    std::vector<PollFd> fds;
    std::vector<std::pair<int, int>> whose;  // each socket polled: its relay and leg (-1: the server's own port)
    char packet[kMostPacket];
    int64_t expired = nowMs();
    while (running_.load(std::memory_order_acquire)) {
        fds.clear();
        whose.clear();
        fds.push_back(PollFd{st.main, POLLIN, 0});
        whose.push_back({-1, 0});
        for (size_t i = 0; i < st.relays.size(); ++i)
            for (int leg = 0; leg < 2; ++leg) {
                fds.push_back(PollFd{st.relays[i].legs[leg].socket, POLLIN, 0});
                whose.push_back({int(i), leg});
            }
        pollAll(fds.data(), fds.size(), 100);
        for (size_t k = 0; k < fds.size(); ++k) {
            if (!(fds[k].revents & POLLIN)) continue;
            const int relay = whose[k].first;
            if (relay >= 0 && st.relays[size_t(relay)].legs[whose[k].second].socket != fds[k].fd) continue;  // (closed meanwhile)
            for (int reads = 0; reads < 256; ++reads) {  // (all there is, but never one socket alone for long)
                sockaddr_in from{};
                socklen_t from_size = sizeof(from);
                const int size = int(recvfrom(fds[k].fd, packet, int(sizeof(packet)), 0, reinterpret_cast<sockaddr*>(&from), &from_size));
                if (size < 0) break;
                if (relay < 0) st.onMain(packet, size_t(size), from);
                else st.onRelay(st.relays[size_t(relay)], whose[k].second, packet, size_t(size), from);
                if (relay >= 0 && st.relays[size_t(relay)].legs[whose[k].second].socket == kNoSocket) break;
            }
        }
        const int64_t now = nowMs();
        if (now - expired >= 1000) {
            expired = now;
            st.expire(now);
        }
        st.compact();
        std::lock_guard<std::mutex> lock(st.counts_mutex);
        st.counts.sessions = int(st.sessions.size());
        st.counts.relays = int(st.relays.size());
        st.counts.relayed = st.relayed;
    }
}

}  // namespace sr
