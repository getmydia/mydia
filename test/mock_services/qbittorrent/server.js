const express = require("express");
const bodyParser = require("body-parser");
const cookieParser = require("cookie-parser");

const app = express();
const PORT = process.env.PORT || 8080;
const USERNAME = process.env.USERNAME || "admin";
const PASSWORD = process.env.PASSWORD || "adminpass";

// Which qBittorrent WebAPI dialect to emulate.
//   5.1 -> login returns 200 "Ok."  and sets SID
//   5.2 -> login returns 204 empty  and sets QBT_SID_<port>
// 5.2 is the default because that is what current installs speak. The port in
// the cookie name is the server's own listening port, matching real behaviour.
const DIALECT = process.env.QB_DIALECT || "5.2";
const SESSION_COOKIE = DIALECT === "5.1" ? "SID" : `QBT_SID_${PORT}`;
const APP_VERSION = DIALECT === "5.1" ? "v5.1.2-mock" : "v5.2.0-mock";

app.use(bodyParser.urlencoded({ extended: true }));
app.use(bodyParser.json());
app.use(cookieParser());

// In-memory session storage
const sessions = new Map();
const torrents = new Map();

// Generate simple session ID
function generateSessionId() {
  return Math.random().toString(36).substring(2, 15);
}

// Middleware to check authentication
const requireAuth = (req, res, next) => {
  const sid = req.cookies[SESSION_COOKIE];
  if (!sid || !sessions.has(sid)) {
    return res.status(403).send("Forbidden");
  }
  next();
};

// Health check endpoint
app.get("/health", (req, res) => {
  res.json({ status: "ok" });
});

// Login endpoint
app.post("/api/v2/auth/login", (req, res) => {
  const { username, password } = req.body;

  if (username === USERNAME && password === PASSWORD) {
    const sid = generateSessionId();
    sessions.set(sid, { username, loginTime: Date.now() });
    res.cookie(SESSION_COOKIE, sid, { httpOnly: true, sameSite: "Strict" });
    return DIALECT === "5.1" ? res.send("Ok.") : res.status(204).end();
  }

  res.status(401).send("Fails.");
});

// Logout endpoint
app.post("/api/v2/auth/logout", (req, res) => {
  const sid = req.cookies[SESSION_COOKIE];
  if (sid) {
    sessions.delete(sid);
    res.clearCookie(SESSION_COOKIE);
  }
  res.send("Ok.");
});

// Get application version
app.get("/api/v2/app/version", (req, res) => {
  res.send(APP_VERSION);
});

// Get application preferences
app.get("/api/v2/app/preferences", requireAuth, (req, res) => {
  res.json({
    save_path: "/downloads",
    temp_path_enabled: false,
    preallocate_all: false,
    incomplete_files_ext: false,
  });
});

// Get torrent list
app.get("/api/v2/torrents/info", requireAuth, (req, res) => {
  const torrentList = Array.from(torrents.values());
  res.json(torrentList);
});

// Add torrent
app.post("/api/v2/torrents/add", requireAuth, (req, res) => {
  const { urls, savepath, category } = req.body;

  if (!urls) {
    return res.status(400).send("Missing urls parameter");
  }

  const urlList = Array.isArray(urls) ? urls : [urls];

  urlList.forEach((url) => {
    const hash = Math.random().toString(36).substring(2, 42);
    const name = url.includes("urn:btih:")
      ? `Torrent ${hash.substring(0, 8)}`
      : url.split("/").pop() || `Torrent ${hash.substring(0, 8)}`;

    torrents.set(hash, {
      hash,
      name,
      size: Math.floor(Math.random() * 5000000000) + 1000000000,
      progress: 0,
      dlspeed: 0,
      upspeed: 0,
      priority: 1,
      num_seeds: 0,
      num_complete: 0,
      num_leechs: 0,
      num_incomplete: 0,
      ratio: 0,
      eta: 8640000,
      state: "downloading",
      seq_dl: false,
      f_l_piece_prio: false,
      category: category || "",
      tags: "",
      save_path: savepath || "/downloads",
      added_on: Math.floor(Date.now() / 1000),
      completion_on: -1,
      tracker: url.includes("magnet:") ? "Magnet Link" : "HTTP Seed",
      dl_limit: -1,
      up_limit: -1,
      downloaded: 0,
      uploaded: 0,
      downloaded_session: 0,
      uploaded_session: 0,
      amount_left: 0,
      auto_tmm: false,
      time_active: 0,
      seeding_time: 0,
      availability: -1,
    });
  });

  res.send("Ok.");
});

// Delete torrents
app.post("/api/v2/torrents/delete", requireAuth, (req, res) => {
  const { hashes, deleteFiles } = req.body;

  if (!hashes) {
    return res.status(400).send("Missing hashes parameter");
  }

  const hashList = hashes.split("|");
  hashList.forEach((hash) => {
    if (hash === "all") {
      torrents.clear();
    } else {
      torrents.delete(hash);
    }
  });

  res.send("Ok.");
});

// Pause torrents
app.post("/api/v2/torrents/pause", requireAuth, (req, res) => {
  const { hashes } = req.body;

  if (!hashes) {
    return res.status(400).send("Missing hashes parameter");
  }

  const hashList = hashes.split("|");
  hashList.forEach((hash) => {
    const torrent = torrents.get(hash);
    if (torrent) {
      torrent.state = "pausedDL";
      torrent.dlspeed = 0;
      torrent.upspeed = 0;
    }
  });

  res.send("Ok.");
});

// Resume torrents
app.post("/api/v2/torrents/resume", requireAuth, (req, res) => {
  const { hashes } = req.body;

  if (!hashes) {
    return res.status(400).send("Missing hashes parameter");
  }

  const hashList = hashes.split("|");
  hashList.forEach((hash) => {
    const torrent = torrents.get(hash);
    if (torrent) {
      torrent.state = "downloading";
    }
  });

  res.send("Ok.");
});

// Get torrent properties
app.get("/api/v2/torrents/properties", requireAuth, (req, res) => {
  const { hash } = req.query;

  const torrent = torrents.get(hash);
  if (!torrent) {
    return res.status(404).json({ error: "Torrent not found" });
  }

  res.json({
    save_path: torrent.save_path,
    creation_date: torrent.added_on,
    piece_size: 4194304,
    comment: "",
    total_wasted: 0,
    total_uploaded: torrent.uploaded,
    total_uploaded_session: torrent.uploaded_session,
    total_downloaded: torrent.downloaded,
    total_downloaded_session: torrent.downloaded_session,
    up_limit: torrent.up_limit,
    dl_limit: torrent.dl_limit,
    time_elapsed: torrent.time_active,
    seeding_time: torrent.seeding_time,
    nb_connections: 0,
    nb_connections_limit: 100,
    share_ratio: torrent.ratio,
    addition_date: torrent.added_on,
    completion_date: torrent.completion_on,
    created_by: "Mock qBittorrent",
    dl_speed_avg: 0,
    dl_speed: torrent.dlspeed,
    eta: torrent.eta,
    last_seen: Math.floor(Date.now() / 1000),
    peers: 0,
    peers_total: 0,
    pieces_have: 0,
    pieces_num: 1000,
    reannounce: 0,
    seeds: torrent.num_seeds,
    seeds_total: torrent.num_complete,
    total_size: torrent.size,
    up_speed_avg: 0,
    up_speed: torrent.upspeed,
  });
});

// Simulate torrent progress
setInterval(() => {
  torrents.forEach((torrent) => {
    if (torrent.state === "downloading" && torrent.progress < 1) {
      torrent.progress += 0.05;
      torrent.dlspeed = Math.floor(Math.random() * 10000000) + 1000000;
      torrent.downloaded += torrent.dlspeed;

      if (torrent.progress >= 1) {
        torrent.progress = 1;
        torrent.state = "uploading";
        torrent.dlspeed = 0;
        torrent.completion_on = Math.floor(Date.now() / 1000);
      }
    } else if (torrent.state === "uploading") {
      torrent.upspeed = Math.floor(Math.random() * 5000000) + 500000;
      torrent.uploaded += torrent.upspeed;
      torrent.ratio = torrent.uploaded / torrent.size;
    }
    torrent.time_active += 5;
    if (torrent.state === "uploading") {
      torrent.seeding_time += 5;
    }
  });
}, 5000);

app.listen(PORT, "0.0.0.0", () => {
  console.log(`Mock qBittorrent server listening on port ${PORT}`);
  console.log(`Username: ${USERNAME}`);
  console.log(`Password: ${PASSWORD}`);
});
