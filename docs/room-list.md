# Setting up the room list

The room list puts rooms hosted over the internet into every player's room browser (the Rooms tab of Play
together), as rooms on one network appear there by themselves. It is a small program on Cloudflare (a Worker, with a
D1 database to keep the rooms in), both on Cloudflare's free plan, with nothing to look after once it is set up.
Everyone uses the same one: it is set up once, and its address goes into Studiolator.

It only lists rooms. A player joining connects straight to the host's computer, at the address the list saw the host
come from, so the host's router must have its ports open: **Over the internet** asks it to (UPnP), and the Rooms tab
marks a room whose router didn't say it had ("ports may be closed").

The code is in `services/room-list`: `worker.js` (the Worker), `schema.sql` (its table) and `wrangler.toml` (for
setting it up from a terminal).

## Setting it up in Cloudflare's dashboard

Nothing needs installing for this.

1. Sign up for a free account at [dash.cloudflare.com](https://dash.cloudflare.com/sign-up).
2. **The database.** In the dashboard, open **Storage & Databases › D1 SQL Database** and create a database named
   `studiolator-rooms`. Open it, go to its **Console**, paste in everything in `services/room-list/schema.sql`, and
   run it. The console then shows a `rooms` table.
3. **The Worker.** Open **Compute (Workers) › Workers & Pages**, choose **Create**, start from the "Hello World"
   Worker, name it `studiolator-rooms`, and deploy it. Then choose **Edit code**, replace everything in it with
   `services/room-list/worker.js`, and deploy again.
4. **Connect the two.** In the Worker's **Settings › Bindings**, add a binding: a **D1 database**, with the variable
   name `DB` (exactly that), and the `studiolator-rooms` database. Save it, which deploys the Worker again.
5. **Try it.** The Worker's page shows its address, something like `https://studiolator-rooms.<yours>.workers.dev`.
   Open that address in a browser: it should say `{"service":"Studiolator room list","rooms":0}`. Adding `/rooms` to
   the address shows the list itself: `{"rooms":[]}`.
6. **Tell Studiolator.** Put the address into `game/scripts/room_list.gd`, as `ADDRESS` near its top, without a
   slash at the end:

   ```gdscript
   const ADDRESS := "https://studiolator-rooms.<yours>.workers.dev"
   ```

   Commit it, and every copy of Studiolator made from the project from then on uses the list. (The automated checks
   never use it: they use a stand-in on the same computer.)

## Setting it up from a terminal instead

With [Node.js](https://nodejs.org) installed, Cloudflare's `wrangler` does the same, from `services/room-list`:

```bash
npx wrangler login
```

```bash
npx wrangler d1 create studiolator-rooms
```

Put the `database_id` that prints into `wrangler.toml`, then:

```bash
npx wrangler d1 execute studiolator-rooms --remote --file=schema.sql
```

```bash
npx wrangler deploy
```

The address it deploys to goes into `room_list.gd`, as in step 6. After changing `worker.js`, `npx wrangler deploy`
puts the new one up. In the dashboard, paste it into **Edit code** again.

## What it costs, and what it shows

Cloudflare's free plan allows 100,000 requests a day, and D1's allows 100,000 rows written a day. A hosted room is
put on the list every 30 seconds, about 2,900 times in a whole day of hosting. A player's Rooms tab asks for the list
every 5 seconds while it is open. That is plenty for a group of friends; a lot of players at once would need
Cloudflare's paid plan, which starts at $5 a month.

The list shows each room's name, host, kind (Jam or Record), players, whether it has a password, and the public
address and port of the host's computer, as any game's server list does. The password itself never goes to it. Each
room is kept on the list by a token only its host has, so nobody else can change or remove it. A room not heard
from for 75 seconds drops off, and one address can list four rooms at most.

## Checking it

`tools/build.sh` checks the Worker (`services/room-list/tests.mjs`, run with Node or a Mac's own JavaScript shell)
and its SQL on SQLite, which D1 is (`python3 services/room-list/stand_in.py --check`). The game's checks host a room
with the list's stand-in running on the same computer, and look for it from another copy of the game.
