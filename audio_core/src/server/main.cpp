// SoundRoom's session server (session_server.h), as a program of its own, for a machine the internet can reach:
//
//   soundroom-session-server [--port 47100] [--bind 0.0.0.0] [--relay-ports 47200-47455] [--quiet]
//
// It goes on until stopped (Ctrl-C, or the system's stop). Every player who meets through it needs its port, and its
// relays' ports, open to UDP in the machine's firewall (with --relay-ports, that range: two ports for each player
// joining by way of it at once; without, any).

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

#include "session_server.h"

namespace {

std::atomic<bool> stopping{false};

void onSignal(int) { stopping.store(true); }

int usage() {
    std::fprintf(stderr, "Usage: soundroom-session-server [--port %d] [--bind 0.0.0.0] [--relay-ports FIRST-LAST] [--quiet]\n",
        sr::SessionServer::kPort);
    return 2;
}

}  // namespace

int main(int argc, char** argv) {
    sr::SessionServer::Options options;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        const bool more = i + 1 < argc;
        if (arg == "--port" && more) {
            options.port = std::atoi(argv[++i]);
        } else if (arg == "--bind" && more) {
            options.bind = argv[++i];
        } else if (arg == "--relay-ports" && more) {
            const std::string range = argv[++i];
            const size_t dash = range.find('-');
            if (dash == std::string::npos) return usage();
            options.relay_from = std::atoi(range.substr(0, dash).c_str());
            options.relay_to = std::atoi(range.substr(dash + 1).c_str());
            if (options.relay_from <= 0 || options.relay_to < options.relay_from) return usage();
            options.most_relays = (options.relay_to - options.relay_from + 1) / 2;
        } else if (arg == "--quiet") {
            options.log = false;
        } else {
            return usage();
        }
    }
    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
    sr::SessionServer server;
    std::string error;
    if (!server.start(options, &error)) {
        std::fprintf(stderr, "The session server couldn't start: %s.\n", error.c_str());
        return 1;
    }
    if (options.log) {
        std::printf("SoundRoom's session server, on UDP port %d%s.\n", server.port(),
            options.relay_from > 0 ? (", relaying on ports " + std::to_string(options.relay_from) + " to " + std::to_string(options.relay_to)).c_str() : "");
        std::fflush(stdout);
    }
    while (!stopping.load()) std::this_thread::sleep_for(std::chrono::milliseconds(200));
    server.stop();
    return 0;
}
