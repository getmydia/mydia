# Serve a page

A plugin can serve its own page inside Mydia and make changes for the signed-in
user, with the user's approval. This guide builds a small "Shelf notes" page:
it lists the user's collections, adds a title to one, and handles the approval
step. The real, larger example is the assistant plugin in
`plugins-extra/assistant_openai`.

For the concepts (grants, ceilings, the journal), see
[Pages and writes on a user's behalf](../explanation/plugin-model.md#pages-and-writes-on-a-users-behalf).
For every field and function, see the [`on-http`](../reference/guest-exports.md#on-http) and the
[page writes](../reference/host-functions.md#page-writes).

## 1. Declare the page

```json
{
  "slug": "shelf-notes",
  "name": "Shelf notes",
  "version": "0.1.0",
  "min_host_version": "0.16.0",
  "page": { "title": "Shelf notes", "icon": "hero-bookmark" },
  "capabilities": {
    "surfaces:page": [],
    "data:read": ["collection"],
    "surfaces:write": ["collections:write"]
  }
}
```

`events:subscribe` is not needed when a plugin declares `surfaces:page`. The
page appears in the navigation once an administrator approves the plugin.

## 2. Serve HTML from `on-http`

Use the `on_http` argument of the plugin macro. The host routes every request
under `/plugins/shelf-notes/app/` to your function, with the path below `/app`.

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    Event, HostError, ListItem, ListRequest, PageRequest, PageResponse, WriteOutcome,
};
use serde_json::{json, Value};

#[mydia_plugin_sdk::plugin(on_http = handle_http)]
fn on_event(_evt: Event) -> Result<String, String> {
    Ok("{}".into())
}

const UI: &str = include_str!("ui.html");

fn handle_http(req: PageRequest) -> Result<PageResponse, String> {
    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/") => page(200, "text/html; charset=utf-8", UI.into()),
        ("POST", "/api/collections") => list_collections(),
        ("POST", "/api/add") => add_title(&req),
        _ => page(404, "text/plain; charset=utf-8", "Not found".into()),
    }
}

fn page(status: u16, content_type: &str, body: String) -> Result<PageResponse, String> {
    Ok(PageResponse {
        status,
        headers: vec![("content-type".into(), content_type.into())],
        body,
    })
}

fn respond_json(status: u16, value: Value) -> Result<PageResponse, String> {
    page(status, "application/json", value.to_string())
}

fn host_error(e: HostError) -> Result<PageResponse, String> {
    let message = match e {
        HostError::Denied(_) => "That is not allowed for this plugin.",
        HostError::NotFound(_) => "Nothing matches that.",
        HostError::InvalidRequest(_) => "That request was not valid.",
        HostError::Network(_) | HostError::Internal(_) => "Something went wrong. Try again.",
    };
    respond_json(500, json!({ "error": message }))
}
```

The request carries `user_id`, `role` and `session_id`, all verified by the
host. If you keep state (declare `state:kv`), use per-user keys such as
`user/<user_id>/notes`, because page calls can run at the same time as your event
and schedule handlers. Responses are text only.

## 3. Read and write from the page

The page runs in a sandboxed iframe with no cookies, so it authenticates with a
frame token. The host puts it in the frame URL as `?frame_token=`; read it once
and send it back on every request in the `x-mydia-frame-token` header.

```html
<link rel="stylesheet" href="/assets/css/app.css">
<ul id="list"></ul>
<script>
  let token = new URLSearchParams(location.search).get("frame_token") || ""
  const base = location.pathname.replace(/\/$/, "")

  const api = (path, body) =>
    fetch(`${base}/api/${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-mydia-frame-token": token },
      body: JSON.stringify(body || {}),
    })

  // The token lives one hour. The host sends a fresh one every 45 minutes.
  window.addEventListener("message", (e) => {
    if (e.source !== window.parent || !e.data) return
    if (e.data.mydia === "token" && e.data.token) token = e.data.token
  })

  api("collections").then((r) => r.json()).then(({ collections = [] }) => {
    const list = document.getElementById("list")
    for (const c of collections) {
      const li = document.createElement("li")
      li.textContent = c.name
      list.appendChild(li)
    }
  })
</script>
```

On the guest side, a write returns a `WriteOutcome`. Pass `Done` results through
and report a parked write's id to the page:

```rust
fn list_collections() -> Result<PageResponse, String> {
    let listed = host::data_list(&ListRequest {
        namespace: "collection".into(),
        cursor: None,
        updated_since: None,
        limit: Some(50),
    });

    match listed {
        Ok(page) => {
            let rows: Vec<Value> = page
                .items
                .into_iter()
                .filter_map(|item| match item {
                    ListItem::Collection(c) => Some(json!({ "id": c.id, "name": c.name })),
                    _ => None,
                })
                .collect();
            respond_json(200, json!({ "collections": rows }))
        }
        Err(e) => host_error(e),
    }
}

fn add_title(req: &PageRequest) -> Result<PageResponse, String> {
    // The host hands the body over untouched; parsing it is the guest's job.
    let body: Value = serde_json::from_str(req.body.as_deref().unwrap_or("{}"))
        .map_err(|e| e.to_string())?;
    let collection_id = body["collectionId"].as_str().unwrap_or_default().to_string();
    let item_id = body["itemId"].as_str().unwrap_or_default().to_string();

    match host::collection_add_items(&collection_id, &[item_id]) {
        Ok(WriteOutcome::Done(result)) => respond_json(200, json!({ "done": result })),
        Ok(WriteOutcome::NeedsConfirmation(id)) => respond_json(200, json!({ "pending": [id] })),
        Err(e) => host_error(e),
    }
}
```

The example depends on `serde_json` in addition to the SDK.

## 4. Ask the host to confirm

When the response says `pending`, hand the ids to the host. It shows its own
modal (the plugin cannot draw or answer it), then replies with one message:

```js
async function add(collectionId, itemId) {
  const res = await (await api("add", { collectionId, itemId })).json()
  if (res.pending && res.pending.length) {
    window.parent.postMessage({ mydia: "confirm", ids: res.pending }, "*")
  }
}

window.addEventListener("message", (e) => {
  if (e.source !== window.parent || !e.data) return
  switch (e.data.mydia) {
    case "confirmed":
      // e.data.results: [{ id, ok, result, error }] for each pending write.
      break
    case "denied":
      // e.data.ids: the user said no. Nothing changed.
      break
    case "expired":
      // e.data.ids: the approval is gone (an hour passed or the session changed). Ask again.
      break
    case "theme":
      // e.data.theme: "mydia-dark" or "mydia-light". Sent on load and when the user switches.
      document.documentElement.setAttribute("data-theme", e.data.theme)
      break
  }
})
```

Details worth knowing:

- Send at most 50 ids per `confirm`. Extras are dropped.
- While the modal is open, a second `confirm` is ignored, so collect the ids of
  one action into one message.
- The `confirmed` result for each write is either `ok: true` with the host's
  result, or `ok: false` with an `error` message.
- If the user picked "for this session" or "always", later writes to the same
  surface return `Done` directly and no modal appears.
- Whatever the outcome, nothing reaches the page until the user has decided.
- The host posts `{mydia: "theme", theme}` when your page loads and whenever
  the user changes theme. Set it on your `<html>` so daisyUI's theme variables
  match the host. Without it your page follows the operating system theme.

## Know the limits

The host serves your response with its own security headers, so the page can
only call itself and loads nothing from another origin. Mydia's stylesheet is at
`/assets/css/app.css`, so daisyUI classes work. The headers are listed under
[Page response headers](../reference/guest-exports.md#page-response-headers).
Body size and timeouts are in [Limits](../reference/limits.md#pages). The
statuses the host answers with (401, 404, 413, 415, 502, 503, 504) are listed
under [`on-http`](../reference/guest-exports.md#on-http). When the host answers
503 with `Retry-After`, show a "try again" message rather than an error.

## Undo and the activity page

Every write a page makes is journaled for the user. Users find them at
`/plugins/shelf-notes/activity` (linked from the page's header) and can undo a
single change or a whole batch. Operators set how long a grant may last for each
role.

## Try it

Build the guest and sideload it as in
[Test and iterate](test-and-iterate.md). The fixture used by Mydia's own tests,
`test/support/fixtures/plugins/page_fixture`, shows every page host function in
a few lines each.
