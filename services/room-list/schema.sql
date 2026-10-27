-- StudioSim's room list (worker.js): one row for each room hosted over the internet.
CREATE TABLE IF NOT EXISTS rooms (
  id TEXT PRIMARY KEY,
  token TEXT NOT NULL,
  name TEXT NOT NULL,
  host TEXT NOT NULL,
  mode TEXT NOT NULL,
  players INTEGER NOT NULL,
  most INTEGER NOT NULL,
  locked INTEGER NOT NULL,
  address TEXT NOT NULL,
  port INTEGER NOT NULL,
  protocol INTEGER NOT NULL,
  open INTEGER NOT NULL,
  updated INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS rooms_updated ON rooms (updated);
