# Build a media-server plugin with a setup wizard

A media-server plugin lets an operator add one or more servers from
Admin > Configuration > Media Servers. Mydia renders the wizard: your plugin only says which
screen comes next. This guide builds the connection part of a plugin for an
invented media server called Tallyho. It asks for a server address and an API
key, checks them, stores the key, and reports the server's health afterwards.

The bundled Plex plugin (`plugins/plex`) is the larger, real version. It adds
sign-in with a code, a server picker and a mapping of users to accounts.

For every record and field, see the [`setup`](../reference/guest-exports.md#setup)
and [`check-health`](../reference/guest-exports.md#check-health) references. For
the build and install steps, see [Test and iterate](test-and-iterate.md).

## 1. Declare the plugin

```json
{
  "slug": "tallyho",
  "name": "Tallyho",
  "version": "0.1.0",
  "min_host_version": "0.16.0",
  "multi_instance": true,
  "category": "media_server",
  "setup": true,
  "capabilities": {
    "events:subscribe": ["media_file.imported"],
    "net:http": [],
    "state:kv": [],
    "users:connections": []
  },
  "connection": {
    "type": "none",
    "auth_header": "X-Tallyho-Key: {token}"
  }
}
```

- `multi_instance` lets an operator add several Tallyho servers. Each instance
  has its own store, credentials and health.
- `category: "media_server"` lists the plugin in the **Add server** menu on
  Admin > Configuration > Media Servers.
- `setup: true` tells the host to create instances through your `setup` export.
- `net:http` is empty because the server address is not known in advance. The
  address the operator types into a `url` field is approved for that instance
  only. See [`http-request`](../reference/host-functions.md#http-request).
- `connection.auth_header` is the header the host adds when you call
  [`link-request`](../reference/host-functions.md#link-request). The token never
  reaches your code.
- A manifest must declare at least one of `events:subscribe`, `surfaces:page`
  or `surfaces:shelf` (see [`events:subscribe`](../reference/capabilities.md#eventssubscribe)).
  This plugin subscribes to `media_file.imported`, the event a real plugin would
  use to refresh the server's library.

All fields are in the [manifest reference](../reference/manifest.md).

## 2. Return a form first

The crate layout is the one from the
[tutorial](../tutorial/write-your-first-plugin.md), with one extra dependency.
In `Cargo.toml`:

```toml
[dependencies]
mydia-plugin-sdk = { git = "https://github.com/getmydia/mydia", tag = "v0.16.0-beta.2" }
serde_json = "1"
```

Use the `setup` and `check_health` arguments of the plugin macro. The host calls
`setup` with `step = "start"` when the operator adds the instance, so the first
screen is a form:

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    Credential, Event, FormScreen, Health, HealthAction, HealthStatus, LinkRole, OutboundRequest,
    ScreenBody, SetupField, SetupRequest, SetupScreen,
};
use serde_json::Value;

const URL_KEY: &str = "server/url";

#[mydia_plugin_sdk::plugin(setup = setup, check_health = check_health)]
fn on_event(_evt: Event) -> Result<String, String> {
    Ok("{}".into())
}

fn screen(step: &str, body: ScreenBody) -> SetupScreen {
    SetupScreen {
        step: step.into(),
        body,
        next_state_json: "{}".into(),
        credentials: vec![],
        error: None,
    }
}

fn connect_form(error: Option<String>) -> SetupScreen {
    let field = |key: &str, label: &str, field_type: &str| SetupField {
        key: key.into(),
        label: label.into(),
        field_type: field_type.into(),
        required: true,
        options: vec![],
        default_value: None,
    };
    let form = ScreenBody::Form(FormScreen {
        title: "Connect Tallyho".into(),
        fields: vec![
            field("url", "Server URL, for example http://192.168.1.30:8096", "url"),
            field("api_key", "API key", "secret"),
        ],
    });
    SetupScreen { error, ..screen("connect", form) }
}

fn setup(req: SetupRequest) -> Result<SetupScreen, String> {
    match req.step.as_str() {
        "start" => Ok(connect_form(None)),
        "connect" => connect(&req.input_json),
        other => Err(format!("unknown setup step {other}")),
    }
}
```

The `step` of a screen is the id the host sends back with the operator's
answer, so the form above comes back as `"connect"`. The answers arrive in
`input_json`, keyed by each field's `key`. A `url` field is approved as an
endpoint of the instance when the operator submits the form, before your
`connect` step runs. The host also refuses an empty answer to a `required`
field.

## 3. Check the answers and finish with `done`

Try the server before you store anything. The `url` is already approved, but
the API key is not a credential yet, so pass it in a header yourself for this
one call:

```rust
fn status_request(url: &str, headers: Vec<(String, String)>) -> OutboundRequest {
    OutboundRequest {
        url: format!("{url}/api/status"),
        method: "GET".into(),
        headers,
        body: None,
    }
}

fn connect(input_json: &str) -> Result<SetupScreen, String> {
    let input: Value = serde_json::from_str(input_json).map_err(|e| e.to_string())?;
    let url = input["url"].as_str().unwrap_or_default().trim_end_matches('/').to_string();
    let api_key = input["api_key"].as_str().unwrap_or_default().trim().to_string();

    let probe = host::http_request(&status_request(
        &url,
        vec![("x-tallyho-key".into(), api_key.clone())],
    ));
    match probe {
        Ok(resp) if resp.ok => {}
        Ok(resp) if resp.status == 401 || resp.status == 403 => {
            return Ok(connect_form(Some("Tallyho rejected that API key.".into())));
        }
        Ok(resp) => {
            return Ok(connect_form(Some(format!("Tallyho answered with {}.", resp.status))));
        }
        Err(e) => return Ok(connect_form(Some(format!("Could not reach Tallyho: {e:?}")))),
    }

    // `check-health` receives no arguments, so keep the address in the store.
    host::kv_set(URL_KEY, &url).map_err(|e| format!("store: {e:?}"))?;

    Ok(SetupScreen {
        credentials: vec![Credential { role: LinkRole::Owner, token: api_key }],
        ..screen("done", ScreenBody::Done(format!("Connected to {url}.")))
    })
}
```

Two things to notice:

- A failed check returns the form again with `error` set. The host shows the
  message above the screen and keeps the operator on it. Return `Err` only for
  a bug, not for a wrong answer.
- `credentials` on a screen holds the tokens the host should store. They are
  applied as the screen is received, and the host keeps each one as a link of
  the instance with the role you give it (`owner` or `endpoint`). The
  `done` screen finishes the wizard and enables the new instance, and its string
  is the summary shown to the operator.

## 4. Implement `check-health`

The host calls `check-health` every five minutes for each enabled instance and
when the operator presses Test. Use the stored credential through `link-request`
and report what you find:

```rust
fn health(status: HealthStatus, message: &str, action: Option<HealthAction>) -> Result<Health, String> {
    Ok(Health { status, message: Some(message.into()), action })
}

fn check_health() -> Result<Health, String> {
    let Some(url) = host::kv_get(URL_KEY).map_err(|e| format!("store: {e:?}"))? else {
        return health(HealthStatus::Unreachable, "No server address stored.", Some(HealthAction::Reconnect));
    };
    let links = host::links_list().map_err(|e| format!("links-list: {e:?}"))?;
    let Some(owner) = links.into_iter().find(|l| l.role == LinkRole::Owner) else {
        return health(HealthStatus::Unauthorized, "No API key stored.", Some(HealthAction::Reconnect));
    };

    match host::link_request(&owner.id, &status_request(&url, vec![])) {
        Ok(resp) if resp.ok => Ok(Health { status: HealthStatus::Ok, message: None, action: None }),
        Ok(resp) if resp.status == 401 || resp.status == 403 => health(
            HealthStatus::Unauthorized,
            "Tallyho rejected the stored API key.",
            Some(HealthAction::Reconnect),
        ),
        Ok(resp) => health(HealthStatus::Degraded, &format!("Tallyho answered with {}.", resp.status), None),
        Err(e) => health(HealthStatus::Unreachable, &format!("Tallyho did not answer: {e:?}"), None),
    }
}
```

`action: Some(HealthAction::Reconnect)` shows a button that runs your wizard
again from `start`. If your guest returns `Err` or times out, the host shows the
instance as `unreachable` with the error as the message. Every status the host
derives itself is listed under
[`check-health`](../reference/guest-exports.md#check-health).

The wizard has more screens than a form. A `choice` screen offers options and
can carry the endpoints and credentials of the option the operator picks. An
`external-auth` screen sends the operator to a sign-in page while the host calls
`setup` with `step = "poll"`. A `mapping` screen pairs the server's accounts with
Mydia users. Their records are under [Screens](../reference/guest-exports.md#screens).

## 5. Build and install

Build the component and install it with the manifest from step 1. The
[Test and iterate](test-and-iterate.md) guide covers this loop in full:

```bash
cargo build --release --target wasm32-wasip2
./dev mix mydia.plugin install target/wasm32-wasip2/release/tallyho.wasm manifest.json --approve
./dev restart
```

## 6. Add an instance

Open **Admin > Configuration > Media Servers**, choose **Add server**, and pick **Tallyho**. The
wizard opens with your form. Enter a server address and an API key. When the
check passes, the `done` screen closes the wizard and the instance appears in the
list with its health. Choosing **Add server** again adds a second instance.

## Next steps

- [Build a two-way sync plugin](two-way-sync.md): keep watched state in step
  with a service, per user.
- [Plugin model](../explanation/plugin-model.md): why instances, links and
  approved endpoints exist.
