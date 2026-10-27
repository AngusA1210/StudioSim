// StudioSim's room list: the rooms hosted over the internet, for every player's room browser. A Cloudflare Worker
// with a D1 database (both free), set up as docs/room-list.md says. It only lists rooms: players connect to each other
// directly, to the address the host's computer has on the internet.
//
//   GET    /rooms        the rooms whose hosts have been heard from lately: {"rooms": [{id, name, host, mode, players,
//                        most, locked, address, port, protocol, open}, ...]}
//   POST   /rooms        a host's room, put on the list or kept there (every half minute while it is hosted): JSON
//                        {id, token, name, host, mode, players, most, locked, port, protocol, open, address4?}. Its
//                        address is the one the request came from (address4, the router's, only when that was IPv6).
//                        Only the token that first listed a room can change it.
//   DELETE /rooms/<id>   a room taken off the list (the session ended): JSON {token}
//   GET    /             what this is, and how many rooms are listed
//
// A room not heard from for 75 seconds is no longer listed. One address lists four rooms at most.

const FRESH_MS = 75000;
const MOST_PER_ADDRESS = 4;
const MOST_LISTED = 200;
const MODES = ["jam", "record"];

export default {
  async fetch(request, env) {
    try {
      return await handle(request, env.TEST_STORE ?? d1Store(env.DB), Date.now());
    } catch (error) {
      return reply({ error: "the room list had a problem: " + String(error && error.message ? error.message : error) }, 500);
    }
  },
};

async function handle(request, store, now) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "");
  const since = now - FRESH_MS;
  if (request.method === "GET" && path === "") {
    return reply({ service: "StudioSim room list", rooms: (await store.list(since, MOST_LISTED)).length });
  }
  if (request.method === "GET" && path === "/rooms") {
    return reply({ rooms: await store.list(since, MOST_LISTED) });
  }
  if (request.method === "POST" && path === "/rooms") {
    const body = await bodyOf(request);
    const room = roomFrom(body, request.headers.get("CF-Connecting-IP") || "", now);
    if (typeof room === "string") return reply({ error: room }, 400);
    if ((await store.count(room.address, room.id, since)) >= MOST_PER_ADDRESS) {
      return reply({ error: "this address lists as many rooms as it may" }, 429);
    }
    if (!(await store.put(room))) return reply({ error: "that room is someone else's" }, 403);
    if (Math.random() < 0.05) await store.prune(since);
    return reply({ listed: true, address: room.address });
  }
  if (request.method === "DELETE" && path.startsWith("/rooms/")) {
    const body = await bodyOf(request);
    const id = decodeURIComponent(path.slice("/rooms/".length));
    await store.remove(id, String(body.token || ""));
    return reply({ removed: true });
  }
  return reply({ error: "not found" }, 404);
}

async function bodyOf(request) {
  try {
    const body = await request.json();
    return body && typeof body === "object" ? body : {};
  } catch (error) {
    return {};
  }
}

// A host's room as it is to be listed, or what is wrong with it.
function roomFrom(body, from, now) {
  const text = (value, most) => (typeof value === "string" ? value.trim().slice(0, most) : "");
  const whole = (value, least, most) => (Number.isInteger(value) && value >= least && value <= most ? value : null);
  const id = text(body.id, 64);
  const token = text(body.token, 128);
  if (!/^[A-Za-z0-9]{8,64}$/.test(id)) return "the room's id isn't one";
  if (!/^[A-Za-z0-9]{16,128}$/.test(token)) return "the room's token isn't one";
  const name = text(body.name, 40);
  const host = text(body.host, 24);
  if (name === "" || host === "") return "a room needs a name, and its host one";
  if (!MODES.includes(body.mode)) return "a room is a Jam room or a Record room";
  const players = whole(body.players, 1, 64);
  const most = whole(body.most, 2, 64);
  const port = whole(body.port, 1024, 65535);
  const protocol = whole(body.protocol, 1, 100000);
  if (players === null || most === null || port === null || protocol === null) return "a room's numbers aren't right";
  let address = from;
  if (address.includes(":")) {  // (IPv6: the sound between players goes by IPv4, so the router's address, as it gave it)
    address = isIPv4(body.address4) ? body.address4 : "";
  }
  if (!isIPv4(address)) return "an IPv4 address is wanted for the room";
  return { id, token, name, host, mode: body.mode, players, most, locked: body.locked === true, address, port, protocol,
    open: body.open === true, updated: now };
}

function isIPv4(value) {
  if (typeof value !== "string" || !/^\d{1,3}(\.\d{1,3}){3}$/.test(value)) return false;
  return value.split(".").every((part) => Number(part) <= 255);
}

function reply(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json; charset=utf-8" } });
}

// The rooms kept in D1 (schema.sql).
function d1Store(db) {
  const shown = (row) => ({ id: row.id, name: row.name, host: row.host, mode: row.mode, players: row.players, most: row.most,
    locked: row.locked === 1, address: row.address, port: row.port, protocol: row.protocol, open: row.open === 1 });
  return {
    async list(since, limit) {
      const { results } = await db.prepare("SELECT * FROM rooms WHERE updated > ? ORDER BY name COLLATE NOCASE LIMIT ?").bind(since, limit).all();
      return results.map(shown);
    },
    async count(address, exceptId, since) {
      const row = await db.prepare("SELECT COUNT(*) AS n FROM rooms WHERE address = ? AND id != ? AND updated > ?").bind(address, exceptId, since).first();
      return row ? row.n : 0;
    },
    async put(room) {
      const result = await db.prepare(
        "INSERT INTO rooms (id, token, name, host, mode, players, most, locked, address, port, protocol, open, updated) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, host = excluded.host, " +
        "mode = excluded.mode, players = excluded.players, most = excluded.most, locked = excluded.locked, address = excluded.address, " +
        "port = excluded.port, protocol = excluded.protocol, open = excluded.open, updated = excluded.updated WHERE rooms.token = excluded.token"
      ).bind(room.id, room.token, room.name, room.host, room.mode, room.players, room.most, room.locked ? 1 : 0, room.address, room.port,
        room.protocol, room.open ? 1 : 0, room.updated).run();
      return result.meta.changes > 0;
    },
    async remove(id, token) {
      await db.prepare("DELETE FROM rooms WHERE id = ? AND token = ?").bind(id, token).run();
    },
    async prune(before) {
      await db.prepare("DELETE FROM rooms WHERE updated <= ?").bind(before).run();
    },
  };
}
