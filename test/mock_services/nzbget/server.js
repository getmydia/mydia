const express = require("express");
const bodyParser = require("body-parser");
const fs = require("fs");
const path = require("path");

const app = express();
const PORT = process.env.PORT || 6789;
const USERNAME = process.env.USERNAME || "nzbget";
const PASSWORD = process.env.PASSWORD || "tegbzn6789";

app.use(bodyParser.json());

// In-memory state
const groups = new Map();
const history = new Map();
let nzbIdCounter = 0;

// Basic Auth middleware
const requireAuth = (req, res, next) => {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Basic ")) {
    return res.status(401).json({ error: "Authentication required" });
  }

  const base64 = authHeader.slice(6);
  const decoded = Buffer.from(base64, "base64").toString("utf-8");
  const [user, pass] = decoded.split(":");

  if (user !== USERNAME || pass !== PASSWORD) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  next();
};

// Health check (no auth required)
app.get("/health", (req, res) => {
  res.json({ status: "ok" });
});

// JSON-RPC endpoint
app.post("/jsonrpc", requireAuth, (req, res) => {
  const { method, params, id } = req.body;

  const respond = (result) => {
    res.json({ jsonrpc: "2.0", result, id });
  };

  const respondError = (message) => {
    res.json({ jsonrpc: "2.0", error: { message }, id });
  };

  switch (method) {
    case "version":
      return respond("21.1-mock");

    case "listgroups":
      return respond(Array.from(groups.values()));

    case "history": {
      // params[0] is the Hidden flag (boolean)
      return respond(Array.from(history.values()));
    }

    case "append": {
      // params: [NZBFilename, NZBContent(base64), Category, Priority, AddToTop, AddPaused, DupeKey, DupeScore, DupeMode]
      const nzbId = ++nzbIdCounter;
      const nzbName = params[0]
        ? path.basename(params[0], ".nzb")
        : "upload";

      groups.set(nzbId, {
        NZBID: nzbId,
        NZBName: nzbName,
        Status: "DOWNLOADING",
        FileSizeMB: 1000,
        RemainingSizeMB: 1000,
        DownloadRate: 0,
        DestDir: "",
        MinPostTime: Math.floor(Date.now() / 1000),
        _nzb_filename: params[0] || null,
      });

      return respond(nzbId);
    }

    case "editqueue": {
      // params: [Command, Offset, EditText, [IDs]]
      const command = params[0];
      const ids = params[3] || [];

      if (command === "GroupDelete") {
        let found = false;
        for (const nzbId of ids) {
          if (groups.has(nzbId)) {
            groups.delete(nzbId);
            found = true;
          }
        }
        return respond(found);
      }

      if (command === "GroupPause") {
        for (const nzbId of ids) {
          const group = groups.get(nzbId);
          if (group) {
            group.Status = "PAUSED";
          }
        }
        return respond(true);
      }

      if (command === "GroupResume") {
        for (const nzbId of ids) {
          const group = groups.get(nzbId);
          if (group) {
            group.Status = "DOWNLOADING";
          }
        }
        return respond(true);
      }

      return respond(false);
    }

    default:
      return respondError(`Unknown method: ${method}`);
  }
});

// ---- Test injection endpoints ----

// Inject a completed item into history
app.post("/_test/inject-history", bodyParser.json(), (req, res) => {
  const nzbId = req.body.NZBID || ++nzbIdCounter;
  const item = {
    NZBID: nzbId,
    NZBName: req.body.NZBName || "Test Download",
    Status: req.body.Status || "SUCCESS",
    DestDir: req.body.DestDir || "",
    FileSizeMB: req.body.FileSizeMB || 1000,
    RemainingSizeMB: 0,
    DownloadRate: 0,
    MinPostTime: Math.floor(Date.now() / 1000) - 3600,
    HistoryTime: Math.floor(Date.now() / 1000),
    TotalArticles: 100,
    SuccessArticles: 100,
  };

  history.set(nzbId, item);
  res.json({ status: "ok", NZBID: nzbId });
});

// Inject an active item into groups
app.post("/_test/inject-group", bodyParser.json(), (req, res) => {
  const nzbId = req.body.NZBID || ++nzbIdCounter;
  const item = {
    NZBID: nzbId,
    NZBName: req.body.NZBName || "Test Download",
    Status: req.body.Status || "DOWNLOADING",
    FileSizeMB: req.body.FileSizeMB || 1000,
    RemainingSizeMB: req.body.RemainingSizeMB || 500,
    DownloadRate: 1000000,
    DestDir: req.body.DestDir || "",
    MinPostTime: Math.floor(Date.now() / 1000),
  };

  groups.set(nzbId, item);
  res.json({ status: "ok", NZBID: nzbId });
});

// Create test files in shared volume
app.post("/_test/create-files", bodyParser.json(), (req, res) => {
  const files = req.body.files || [];
  const created = [];

  for (const file of files) {
    const filePath = file.path;
    const size = file.size || 1024;

    try {
      fs.mkdirSync(path.dirname(filePath), { recursive: true });
      const buffer = Buffer.alloc(size, "x");
      fs.writeFileSync(filePath, buffer);
      fs.chmodSync(filePath, 0o644);
      created.push(filePath);
    } catch (err) {
      return res
        .status(500)
        .json({ error: `Failed to create ${filePath}: ${err.message}` });
    }
  }

  res.json({ status: "ok", created });
});

// Reset all state
app.post("/_test/reset", (req, res) => {
  groups.clear();
  history.clear();
  nzbIdCounter = 0;
  res.json({ status: "ok" });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`Mock NZBGet listening on port ${PORT}`);
  console.log(`Auth: ${USERNAME}:${PASSWORD}`);
});
