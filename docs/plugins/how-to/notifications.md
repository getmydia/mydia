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

`host::http_request` is gated by your `net:http` grant: a request to a host you
did not list is denied. List the exact hostnames you contact. The matching
rules are under [`net:http`](../reference/capabilities.md#nethttp), and the
response size and timeout are in [Limits](../reference/limits.md#network).
The call and its errors are described under
[`http-request`](../reference/host-functions.md#http-request). Subscribe only to
names from the [events reference](../reference/events.md#event-catalog).

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

## Choose which events the notifier sends

The bundled Webhook Notifier is a single notifier with one settings form and one
event selection. Use it to decide which events reach your chosen destination,
for example to keep request notifications going to a private ntfy topic while
leaving the busier media events off. Open the notifier's settings in the admin plugins page and use
the **Notify on** chips. Each chip is one event: media added, download
completed, and the three request events (requested, request approved, request
rejected).

Installs that had the notifier before the request events existed keep sending
only media added and download completed until you tick more chips. A fresh
install starts with every event selected. Unticking every chip saves an empty
selection, and the notifier then sends nothing.

To offer the same choice in your own plugin, declare an
[`events` setting](../reference/manifest.md#choosing-events-per-instance). The
host does the filtering, so your handler never sees events the operator turned
off.

## Get an ntfy message when someone requests media

**Goal:** a push notification on your phone each time a user requests a title.

1. Open the Webhook Notifier settings and set **Target service** to `ntfy`.
2. Set **Webhook / server URL** to your topic, for example
   `https://ntfy.example.com/media-requests`. Add an access token if your server
   needs one.
3. Under **Notify on**, tick **Requested**. Tick **Request approved** and
   **Request rejected** too if you want to hear about decisions.
4. Save.

When a user requests a title, ntfy shows the media title and year as the
notification title, with a message that names who asked:

```text
Title:   Moonlit Harbor (2024)
Message: Dana requested Moonlit Harbor (2024)

         Would love this one for movie night.
```

The last paragraph is the note the requester left, and it appears only when they
left one. Approvals read `Approved Moonlit Harbor (2024) for Dana`, or
`Auto-approved ...` when automatic approval handled it. Rejections read
`Rejected Moonlit Harbor (2024) for Dana` followed by the rejection reason when
the admin gave one. Discord instances show the same text.

With the **Custom** target, the request fields are available to your templates
as `{{requester}}`, `{{requester_notes}}`, `{{approved_by}}`,
`{{rejection_reason}}` and `{{media_type}}`, alongside `{{title}}` and
`{{event}}`. The full field list is in the
[events reference](../reference/events.md#media_requestcreated).
