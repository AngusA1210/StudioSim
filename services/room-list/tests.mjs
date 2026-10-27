// The room list's checks (worker.js), its rooms kept in memory in place of D1 (stand_in.py --check checks its SQL).
// Run with Node (node services/room-list/tests.mjs), or with the JavaScript shell a Mac has:
//   /System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc -m services/room-list/tests.mjs
// In the JavaScript shell, the little of URL, Request and Response the Worker uses is made here.

import worker from "./worker.js";

const say = typeof print === "function" ? print : console.log;
let failures = 0;
function check(ok, what, detail = "") {
  say(`  [${ok ? "pass" : "FAIL"}] ${what}  (${detail})`);
  if (!ok) failures += 1;
}

if (typeof URL === "undefined") {
  globalThis.URL = class {
    constructor(url) {
      const match = /^https?:\/\/[^/]+(\/[^?#]*)?/.exec(url);
      this.pathname = match && match[1] ? match[1] : "/";
    }
  };
}
if (typeof Response === "undefined") {
  globalThis.Response = class {
    constructor(body, init) {
      this.body = body;
      this.status = init.status;
    }
    async json() { return JSON.parse(this.body); }
  };
}
const ask = (method, path, body, from = "203.0.113.7") => ({
  method, url: "https://rooms.example.workers.dev" + path,
  headers: { get: (name) => (name === "CF-Connecting-IP" ? from : null) },
  async json() { if (body === undefined) throw new Error("no body"); return body; },
});

// The rooms, as D1 would keep them.
const kept = new Map();
const store = {
  async list(since, limit) {
    return [...kept.values()].filter((r) => r.updated > since).sort((a, b) => a.name.localeCompare(b.name)).slice(0, limit)
      .map(({ token, updated, ...shown }) => shown);
  },
  async count(address, exceptId, since) {
    return [...kept.values()].filter((r) => r.address === address && r.id !== exceptId && r.updated > since).length;
  },
  async put(room) {
    const was = kept.get(room.id);
    if (was && was.token !== room.token) return false;
    kept.set(room.id, room);
    return true;
  },
  async remove(id, token) { if (kept.get(id)?.token === token) kept.delete(id); },
  async prune(before) { for (const [id, r] of kept) if (r.updated <= before) kept.delete(id); },
};
const env = { TEST_STORE: store };
const send = async (method, path, body, from) => {
  const response = await worker.fetch(ask(method, path, body, from), env);
  return { status: response.status, data: await response.json() };
};
const room = (extra = {}) => ({ id: "a1b2c3d4e5f6", token: "tokentokentoken123", name: "Friday jam", host: "Andrew", mode: "jam", players: 1,
  most: 8, locked: false, port: 47130, protocol: 1, open: true, ...extra });

say("StudioSim's room list: checks\n");

let r = await send("POST", "/rooms", room());
let listed = await send("GET", "/rooms");
check(r.status === 200 && listed.data.rooms.length === 1 && listed.data.rooms[0].address === "203.0.113.7" && listed.data.rooms[0].name === "Friday jam" &&
  listed.data.rooms[0].token === undefined, "a host's room is listed at the address it came from, its token kept to itself", JSON.stringify(listed.data.rooms[0]));

r = await send("POST", "/rooms", room({ players: 3, name: "Friday jam, later" }));
listed = await send("GET", "/rooms");
check(r.status === 200 && listed.data.rooms.length === 1 && listed.data.rooms[0].players === 3, "kept on the list by its host, as it is now",
  `${listed.data.rooms[0].players} players`);

r = await send("POST", "/rooms", room({ token: "someoneelsestoken99", name: "Taken over" }));
listed = await send("GET", "/rooms");
check(r.status === 403 && listed.data.rooms[0].name === "Friday jam, later", "a room can't be changed without its token", String(r.status));

const wrong = [room({ mode: "party" }), room({ port: 80 }), room({ name: "  " }), room({ id: "x" }), room({ players: 1.5 })];
const statuses = [];
for (const each of wrong) statuses.push((await send("POST", "/rooms", { ...each, id: each.id === "x" ? "x" : "z9y8x7w6v5" })).status);
check(statuses.every((s) => s === 400), "a room that isn't one isn't listed (its mode, port, name, id, numbers)", statuses.join(", "));

r = await send("POST", "/rooms", room({ id: "ipv6room00" }), "2001:db8::1");
const v6 = await send("POST", "/rooms", room({ id: "ipv6room01", address4: "198.51.100.4" }), "2001:db8::1");
listed = await send("GET", "/rooms");
check(r.status === 400 && v6.status === 200 && listed.data.rooms.some((x) => x.id === "ipv6room01" && x.address === "198.51.100.4"),
  "a host reaching it over IPv6 is listed at the IPv4 address its router gave", `${r.status}, then ${v6.status}`);

const many = [];
for (let i = 0; i < 5; i++) many.push((await send("POST", "/rooms", room({ id: `manyrooms${i}`, token: `manytokens${i}xxxxxxx` }), "192.0.2.9")).status);
check(many.slice(0, 4).every((s) => s === 200) && many[4] === 429, "one address lists four rooms at most", many.join(", "));

await send("DELETE", "/rooms/a1b2c3d4e5f6", { token: "someoneelsestoken99" });
const stays = (await send("GET", "/rooms")).data.rooms.some((x) => x.id === "a1b2c3d4e5f6");
await send("DELETE", "/rooms/a1b2c3d4e5f6", { token: "tokentokentoken123" });
const gone = !(await send("GET", "/rooms")).data.rooms.some((x) => x.id === "a1b2c3d4e5f6");
check(stays && gone, "taken off the list by its host, and only by its host", `${stays}, ${gone}`);

for (const each of kept.values()) each.updated -= 80000;
listed = await send("GET", "/rooms");
const front = await send("GET", "/");
check(listed.data.rooms.length === 0 && front.data.service === "StudioSim room list", "a room not heard from for 75 seconds isn't listed",
  `${listed.data.rooms.length} listed`);

check((await send("GET", "/nothing")).status === 404, "anything else isn't there", "404");

say(failures ? "\nSOME CHECKS FAILED" : "\nAll checks passed");
if (failures) {
  if (typeof process !== "undefined") process.exit(1);
  else if (typeof quit === "function") quit(1);
}
