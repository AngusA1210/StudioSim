# Running a session server

A session server is a small program that players meet through, for when a host's router won't open its ports
(see [Playing together](playing-together.md)). It runs on a machine the internet can reach, such as a rented Linux
server, and it needs no other libraries. One server serves any number of rooms, and everyone who plays together
gives the same one.

## What it does

When a room is hosted over the internet with a session server given, the server gives the host a code
("K7Q-M2D"). Others join with the code instead of an address.

When a player joins, the server tells the host's computer and the joining player's computer where each other is,
as the internet sees them, and both send to each other at once. Most routers take that as leave to let the other's
packets in (UDP hole punching), and the two computers then talk directly. The server isn't in the way after that.

When that doesn't work within five seconds, the server passes everything between the two itself, on two ports of
its own for that player: the session's messages, and the sound between players. This happens on some mobile and
student networks, some offices, and routers that are themselves behind another. The Play together page tells the
player when they're in this way.

It never sees the room itself, only where the players' computers are, and what it passes on. Nothing in playing
together is encrypted, through the server or not.

## Building it

On the machine it will run on (Linux, macOS or Windows), with a C++17 compiler and nothing else:

```bash
c++ -std=c++17 -O2 -pthread -o studiolator-session-server audio_core/src/server/session_server.cpp audio_core/src/server/main.cpp
```

`tools/build.sh` builds it too, as `audio_core/build/studiolator-session-server`.

## Running it

```bash
./studiolator-session-server --relay-ports 47200-47455
```

- `--port N`: the port players reach it on (UDP; 47100 unless given). Players add `:N` to its address if it isn't 47100.
- `--relay-ports FIRST-LAST`: the ports relays are given, two for each player joining by way of it at once (here up to
  128). Without it, the system picks any free port, so the firewall would have to let all UDP in.
- `--bind ADDRESS`: one of the machine's addresses to answer on, rather than all of them.
- `--quiet`: no line for each session and relay.

It goes on until stopped with Ctrl-C (or by the system). The machine's firewall must let UDP in on the port and the
relay range. On a Linux machine with `ufw`:

```bash
sudo ufw allow 47100/udp
sudo ufw allow 47200:47455/udp
```

To keep it running and start it with the machine, a systemd unit (`/etc/systemd/system/studiolator-session-server.service`):

```ini
[Unit]
Description=Studiolator session server
After=network-online.target

[Service]
ExecStart=/usr/local/bin/studiolator-session-server --relay-ports 47200-47455
Restart=always
DynamicUser=yes

[Install]
WantedBy=multi-user.target
```

then `sudo systemctl enable --now studiolator-session-server`.

## What it costs

Introducing players costs almost nothing. A relay costs its player's traffic twice over, in and out. That is about
20 to 40 kb/s for the session itself, and about 130 kb/s for each live input or voice going each way. A recording's
file goes through at up to 8 MB/s while it is sent. A small rented server can relay a few players' sound at once.

Each address can host up to eight sessions at once, and each session can have up to sixteen relays. A session whose host
hasn't been heard from for 40 seconds ends, and a relay unused for a minute closes.
