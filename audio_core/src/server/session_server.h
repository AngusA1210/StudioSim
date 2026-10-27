#pragma once

// Playing together's meeting place: a small program on a machine the internet can reach (a rented server, say), for
// players whose routers won't let others reach them. A player hosting over the internet is given a code by it
// ("K7Q-M2D"), which the others join with in place of an address. It tells a player joining where the host's computer
// is, as the internet sees it, and the host where they are, and each sends to the other at once: most routers then let
// the other's packets in, as answers to their own (UDP hole punching), and the two computers talk directly. Where
// a router won't (some mobile networks, some offices), it passes everything between them itself: the session's
// messages and the sound between players, on two ports of its own for each player joining (a relay).
//
// It knows nothing of Studiolator's rooms: it only introduces players, and passes packets on. All of it is UDP:
//
//   from a player's own socket to the server's port, at least 128 bytes each (so that no answer is bigger than what
//   asked for it, and the server can't be used to flood someone else):
//     SM1 host <nonce> <game port> <sound port> [<local address> …]   → SM1 hosted <nonce> <code> <token>
//     SM1 alive <token>   (every few seconds, from the host)            → SM1 alive, or SM1 gone (no such session)
//     SM1 end <token>
//     SM1 find <code> <nonce>                                           → SM1 found <nonce> <ticket> <address> <game port>
//                                                                          <sound port> [<local address> <game port>
//                                                                          <sound port>], SM1 wait, or SM1 unknown
//     SM1 relay <ticket> <nonce>                                        → SM1 relayed <nonce> <game port> <sound port>
//   from the session's own sockets (the game's, and the sound's), so that the server sees where they are:
//     SM1 at <token or ticket> game|sound   (a ticket's tells the host: SM1 knock <ticket> game|sound <address> <port>)
//     SM1 at <token> relay   (to a relay's port: the host's end of it)
//   from the server to the host, where its requests come from:
//     SM1 knock …, and SM1 relay <ticket> <game port> <sound port> (a joining player's relay, for it to send to)
//
// Sessions not kept alive for 40 seconds end, and relays unused for a minute close.

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>

namespace sr {

class SessionServer {
public:
    static constexpr int kPort = 47100;

    struct Options {
        std::string bind = "0.0.0.0";  // the machine's address it answers on ("0.0.0.0": all of them)
        int port = kPort;              // (0: any the system gives; port() says which)
        int relay_from = 0;            // the ports relays are given, from and to (0: any the system gives)
        int relay_to = 0;
        int most_sessions = 256;
        int most_relays = 256;         // (each is two ports)
        int most_per_address = 8;      // sessions hosted from one address
        bool log = true;               // a line for each session and relay, on standard output
    };
    struct Counts {
        int sessions = 0;
        int relays = 0;
        uint64_t relayed = 0;  // packets passed on
    };

    SessionServer();
    ~SessionServer();
    SessionServer(const SessionServer&) = delete;
    SessionServer& operator=(const SessionServer&) = delete;

    // Begins, in a thread of its own. False, with why, if it couldn't.
    bool start(const Options& options, std::string* error);
    void stop();
    int port() const { return port_; }
    Counts counts() const;

private:
    struct State;
    void run();

    std::unique_ptr<State> state_;
    std::thread thread_;
    std::atomic<bool> running_{false};
    int port_ = 0;
};

}  // namespace sr
