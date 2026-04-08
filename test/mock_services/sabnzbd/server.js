const express = require("express");
const bodyParser = require("body-parser");
const multer = require("multer");
const fs = require("fs");
const path = require("path");

const app = express();
const PORT = process.env.PORT || 8080;
const API_KEY = process.env.API_KEY || "test-api-key";

app.use(bodyParser.urlencoded({ extended: true }));
app.use(bodyParser.json());

// Multer for file uploads
const upload = multer({ storage: multer.memoryStorage() });

// In-memory state
const queue = new Map();
const history = new Map();
let nzoCounter = 0;

// API key validation middleware
const requireApiKey = (req, res, next) => {
  const apikey = req.query.apikey || req.body.apikey;
  if (apikey !== API_KEY) {
    return res.status(403).json({ error: "Access denied" });
  }
  next();
};

// Health check
app.get("/health", (req, res) => {
  res.json({ status: "ok" });
});

// SABnzbd API endpoint - all requests go through /api with mode parameter
app.get("/api", requireApiKey, (req, res) => {
  const mode = req.query.mode;

  switch (mode) {
    case "version":
      return res.json({ version: "4.2.0-mock" });

    case "queue":
      return res.json({
        queue: {
          slots: Array.from(queue.values()),
        },
      });

    case "history": {
      const limit = parseInt(req.query.limit) || 50;
      const slots = Array.from(history.values()).slice(0, limit);
      return res.json({
        history: {
          slots,
          noofslots: history.size,
        },
      });
    }

    case "addurl": {
      const nzoId = `SABnzbd_nzo_${++nzoCounter}`;
      const name = req.query.name || "unknown";
      queue.set(nzoId, {
        nzo_id: nzoId,
        filename: path.basename(name, ".nzb"),
        status: "Downloading",
        mb: "100",
        mbleft: "100",
        kbpersec: "0",
        timeleft: "0:00:00",
        percentage: "0",
      });
      return res.json({ status: true, nzo_ids: [nzoId] });
    }

    default:
      return res.json({ error: `Unknown mode: ${mode}` });
  }
});

// File upload endpoint (POST)
app.post("/api", requireApiKey, upload.single("nzbfile"), (req, res) => {
  const mode = req.query.mode || req.body.mode;

  if (mode === "addfile") {
    const nzoId = `SABnzbd_nzo_${++nzoCounter}`;
    const filename = req.file
      ? path.basename(req.file.originalname, ".nzb")
      : "upload";

    queue.set(nzoId, {
      nzo_id: nzoId,
      filename,
      status: "Downloading",
      mb: "100",
      mbleft: "100",
      kbpersec: "0",
      timeleft: "0:00:00",
      percentage: "0",
      // Store the uploaded filename for test verification
      _uploaded_filename: req.file ? req.file.originalname : null,
    });

    return res.json({ status: true, nzo_ids: [nzoId] });
  }

  return res.json({ error: `Unknown mode: ${mode}` });
});

// ---- Test injection endpoints ----

// Inject a completed item into history
app.post("/_test/inject-history", bodyParser.json(), (req, res) => {
  const item = {
    nzo_id: req.body.nzo_id || `SABnzbd_nzo_${++nzoCounter}`,
    filename: req.body.filename || "Test Download",
    status: req.body.status || "Completed",
    storage: req.body.storage || "",
    path: req.body.storage || "",
    mb: req.body.size_mb || "1000",
    mbleft: "0",
    size: String((req.body.size_mb || 1000) * 1024 * 1024),
    kbpersec: "0",
    timeleft: "0:00:00",
    completed: Math.floor(Date.now() / 1000),
    added: Math.floor(Date.now() / 1000) - 3600,
  };

  history.set(item.nzo_id, item);
  res.json({ status: "ok", nzo_id: item.nzo_id });
});

// Inject an active item into queue
app.post("/_test/inject-queue", bodyParser.json(), (req, res) => {
  const item = {
    nzo_id: req.body.nzo_id || `SABnzbd_nzo_${++nzoCounter}`,
    filename: req.body.filename || "Test Download",
    status: req.body.status || "Downloading",
    mb: req.body.size_mb || "1000",
    mbleft: req.body.remaining_mb || "500",
    kbpersec: "1000",
    timeleft: "0:08:20",
    percentage: "50",
  };

  queue.set(item.nzo_id, item);
  res.json({ status: "ok", nzo_id: item.nzo_id });
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
      // Create file with random-ish content of specified size
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
  queue.clear();
  history.clear();
  nzoCounter = 0;
  res.json({ status: "ok" });
});

// Get info about an uploaded file (for testing naming)
app.get("/_test/uploads/:nzoId", (req, res) => {
  const item = queue.get(req.params.nzoId) || history.get(req.params.nzoId);
  if (!item) {
    return res.status(404).json({ error: "Not found" });
  }
  res.json({
    nzo_id: item.nzo_id,
    filename: item.filename,
    uploaded_filename: item._uploaded_filename || null,
  });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`Mock SABnzbd listening on port ${PORT}`);
  console.log(`API Key: ${API_KEY}`);
});
