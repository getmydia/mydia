# Send Notifications

Two recipes for getting a message out of Mydia and onto a service you watch:
firing on the event itself, and shaping the request body for whichever target
the operator picked. They assume the
[tutorial](../tutorial/write-your-first-plugin.md)'s crate layout and build on
the same typed `Event` handler.

## Post a notification when media is added

**Goal:** when a movie or show is added, POST a message to a webhook.

First, subscribe to the event and request the HTTP host in your
[manifest](../reference/manifest.md):

```json
{
  "slug": "added-notifier",
  "name": "Added Notifier",
  "version": "0.1.0",
  "capabilities": {
    "events:subscribe": ["media_item.added"],
    "net:http": ["example.com"]
  }
}
```

Then handle the event and send the request:

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{Event, OutboundRequest};

#[mydia_plugin_sdk::plugin]
fn on_event(evt: Event) -> Result<String, String> {
    let body = format!(r#"{{"text":"New media: {}"}}"#, evt.event);

    let resp = host::http_request(&OutboundRequest {
        url: "https://example.com/hook".into(),
        method: "POST".into(),
        headers: vec![("content-type".into(), "application/json".into())],
        body: Some(body),
    })
    .map_err(|e| format!("request failed: {e:?}"))?;

    Ok(format!(r#"{{"delivered":{},"status":{}}}"#, resp.ok, resp.status))
}
```

`host::http_request` is gated by your `net:http` grant. The host re-validates
the URL host against your allowlist and runs an SSRF check on every call, so a
request to a host you did not declare is denied.

!!! warning "`net:http` hosts are exact, no wildcards"
    List the exact hostnames you contact (`example.com`, `discord.com`). A
    wildcard subdomain would be a data-exfiltration channel, so the host refuses
    them.

## Send to Discord, ntfy, or a custom webhook

**Goal:** shape the request body for a specific notification service. The body
is just a string, so you build whatever the target expects.

=== "Discord"

    Discord webhooks take a JSON payload with `content` and optional `embeds`:

    ```rust
    let payload = format!(
        r#"{{"content":"{title} was added","embeds":[{{"title":"{title}"}}]}}"#,
        title = title
    );

    host::http_request(&OutboundRequest {
        url: webhook_url,
        method: "POST".into(),
        headers: vec![("content-type".into(), "application/json".into())],
        body: Some(payload),
    })
    ```

=== "ntfy"

    ntfy takes a plain-text body; the topic is in the URL path and metadata
    rides in headers:

    ```rust
    host::http_request(&OutboundRequest {
        url: ntfy_url, // e.g. https://ntfy.sh/my-topic
        method: "POST".into(),
        headers: vec![
            ("content-type".into(), "text/plain".into()),
            ("title".into(), title.clone()),
            ("priority".into(), "4".into()),
        ],
        body: Some(format!("{title} was added")),
    })
    ```

=== "Custom"

    Any webhook: set the method, headers, and body yourself.

    ```rust
    host::http_request(&OutboundRequest {
        url: webhook_url,
        method: "PUT".into(),
        headers: vec![
            ("content-type".into(), "application/json".into()),
            ("x-source".into(), "mydia".into()),
        ],
        body: Some(custom_body),
    })
    ```

Where does `title` come from? The event alone doesn't carry it; the bundled
[webhook notifier](https://github.com/getmydia/mydia/tree/master/plugins/webhook_notifier)
(the reference plugin for this whole recipe) enriches the event via
`data-read` first to pull the media item's title before formatting any of the
three payloads above, then POSTs through the gated `http-request` import for
whichever target the operator selected in a `settings_schema` field. See
[Enrich an event with media details](media-data.md#enrich-an-event-with-media-details)
for that lookup, and
[Read operator settings](media-data.md#read-operator-settings) for how the
selected target and webhook URL arrive at runtime.

The notifier keeps its handler logic in plain functions, unit-tested with
`cargo test`, exactly the pattern in
[Test without a host](test-and-iterate.md#test-without-a-host). Read its
`src/lib.rs` for the complete, tested version, including templated bodies and
query params.
