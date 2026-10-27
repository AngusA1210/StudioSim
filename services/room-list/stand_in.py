"""The room list (worker.js) on this computer, for the game's checks: the same requests, the same answers, its rooms in
SQLite (which D1 is) with the very SQL the Worker uses, read from worker.js. It leaves out what the Worker does to
keep strangers out, which the checks don't need (tests.mjs checks that).

  python3 services/room-list/stand_in.py --port 47190    serves it, on 127.0.0.1, until stopped
  python3 services/room-list/stand_in.py --check         checks the Worker's SQL on SQLite
"""

import json
import pathlib
import re
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = pathlib.Path(__file__).resolve().parent
FRESH_MS = 75000


def worker_sql():
    """Each statement the Worker prepares, by what it starts with."""
    source = (HERE / "worker.js").read_text(encoding="utf-8")
    statements = []
    for found in re.finditer(r"db\.prepare\(\s*((?:\"[^\"]*\"\s*\+?\s*)+)\)", source):
        statements.append("".join(re.findall(r"\"([^\"]*)\"", found.group(1))))
    named = {}
    for sql in statements:
        key = {"SELECT *": "list", "SELECT COUNT": "count", "INSERT": "put", "DELETE FROM rooms WHERE id": "remove",
               "DELETE FROM rooms WHERE updated": "prune"}
        for start, name in key.items():
            if sql.startswith(start):
                named[name] = sql
    return named


class Rooms:
    def __init__(self):
        self.sql = worker_sql()
        self.db = sqlite3.connect(":memory:", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript((HERE / "schema.sql").read_text(encoding="utf-8"))
        self.lock = threading.Lock()

    def list(self, since, limit=200):
        with self.lock:
            rows = self.db.execute(self.sql["list"], (since, limit)).fetchall()
        return [{"id": r["id"], "name": r["name"], "host": r["host"], "mode": r["mode"], "players": r["players"], "most": r["most"],
                 "locked": r["locked"] == 1, "address": r["address"], "port": r["port"], "protocol": r["protocol"], "open": r["open"] == 1}
                for r in rows]

    def count(self, address, except_id, since):
        with self.lock:
            return self.db.execute(self.sql["count"], (address, except_id, since)).fetchone()["n"]

    def put(self, room):
        with self.lock:
            changed = self.db.execute(self.sql["put"], (room["id"], room["token"], room["name"], room["host"], room["mode"], room["players"],
                                                        room["most"], 1 if room["locked"] else 0, room["address"], room["port"],
                                                        room["protocol"], 1 if room["open"] else 0, room["updated"])).rowcount
            self.db.commit()
        return changed > 0

    def remove(self, room_id, token):
        with self.lock:
            self.db.execute(self.sql["remove"], (room_id, token))
            self.db.commit()

    def prune(self, before):
        with self.lock:
            self.db.execute(self.sql["prune"], (before,))
            self.db.commit()


def serve(port):
    rooms = Rooms()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _reply(self, data, status=200):
            body = json.dumps(data).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json; charset=utf-8")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            length = int(self.headers.get("content-length") or 0)
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                body = {}
            return body if isinstance(body, dict) else {}

        def do_GET(self):
            since = int(time.time() * 1000) - FRESH_MS
            if self.path.rstrip("/") == "/rooms":
                self._reply({"rooms": rooms.list(since)})
            else:
                self._reply({"service": "StudioSim room list", "rooms": len(rooms.list(since))})

        def do_POST(self):
            body = self._body()
            room = dict(body, address=self.client_address[0], updated=int(time.time() * 1000))
            room.setdefault("locked", False)
            room.setdefault("open", False)
            if self.path.rstrip("/") != "/rooms" or not all(k in room for k in ("id", "token", "name", "host", "mode", "players", "most", "port", "protocol")):
                self._reply({"error": "a room's details aren't all there"}, 400)
            elif not rooms.put(room):
                self._reply({"error": "that room is someone else's"}, 403)
            else:
                self._reply({"listed": True, "address": room["address"]})

        def do_DELETE(self):
            if self.path.startswith("/rooms/"):
                rooms.remove(self.path[len("/rooms/"):], str(self._body().get("token", "")))
            self._reply({"removed": True})

    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


def check():
    failures = 0

    def said(ok, what, detail=""):
        nonlocal failures
        print("  [%s] %s  (%s)" % ("pass" if ok else "FAIL", what, detail))
        failures += 0 if ok else 1

    print("The room list's SQL, on SQLite\n")
    rooms = Rooms()
    said(set(rooms.sql) == {"list", "count", "put", "remove", "prune"}, "each of the Worker's statements is found", ", ".join(sorted(rooms.sql)))
    now = 1_000_000
    room = {"id": "a1b2c3d4", "token": "t" * 16, "name": "b room", "host": "A", "mode": "jam", "players": 1, "most": 8, "locked": True,
            "address": "203.0.113.7", "port": 47130, "protocol": 1, "open": False, "updated": now}
    put = rooms.put(room)
    second = rooms.put(dict(room, id="z9y8x7w6", token="u" * 16, name="A room"))
    listed = rooms.list(now - FRESH_MS)
    said(put and second and [r["name"] for r in listed] == ["A room", "b room"] and listed[1]["locked"] is True and "token" not in listed[0],
         "rooms are listed by name (whatever their case), their tokens kept back", str([r["name"] for r in listed]))
    again = rooms.put(dict(room, players=3, updated=now + 1))
    taken = rooms.put(dict(room, token="x" * 16, name="Taken", updated=now + 2))
    listed = {r["id"]: r for r in rooms.list(now - FRESH_MS)}
    said(again and not taken and listed["a1b2c3d4"]["players"] == 3 and listed["a1b2c3d4"]["name"] == "b room",
         "its host keeps it on the list; another token changes nothing", "%s, %s" % (again, taken))
    said(rooms.count("203.0.113.7", "a1b2c3d4", now - FRESH_MS) == 1 and rooms.count("198.51.100.1", "", now - FRESH_MS) == 0,
         "the rooms at an address are counted, but the one being listed", "")
    rooms.remove("a1b2c3d4", "x" * 16)
    stays = any(r["id"] == "a1b2c3d4" for r in rooms.list(now - FRESH_MS))
    rooms.remove("a1b2c3d4", "t" * 16)
    gone = not any(r["id"] == "a1b2c3d4" for r in rooms.list(now - FRESH_MS))
    rooms.prune(now + 10)
    said(stays and gone and rooms.list(0) == [], "a room is taken off only with its token; old ones are let go", "%s, %s" % (stays, gone))
    print("\n" + ("SOME CHECKS FAILED" if failures else "All checks passed"))
    return 1 if failures else 0


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(check())
    serve(int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 47190)
