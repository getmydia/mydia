# Media request notifications

Issue: #1512

## Goal

An admin wants to know when a user requests media, on their own notification
service (ntfy in the issue), with who asked and what they asked for in the
message itself.

Mydia already ships a Webhook Notifier plugin that posts to Discord, ntfy or a
templated custom webhook. Two things stand in the way:

1. `Mydia.MediaRequests` emits no events, and no `media_request.*` type exists
   in the plugin event catalog, so nothing can subscribe to requests.
2. Every enabled notifier instance receives every event the manifest
   subscribes to. Adding request events to the manifest would make a Discord
   instance shared with users start posting "Alice requested X". The operator
   needs to choose events per instance.

## Decisions

- Notifiable request events: **created, approved, rejected**. Withdrawals
  (cancel) emit nothing.
- Per-instance event selection is a **generic host feature**: a new manifest
  setting type, filtered by the host before anything is enqueued. Any plugin
  may use it.
- Instances that existed before the upgrade keep today's behaviour
  (`media_item.added`, `download.completed`). Instances created after it start
  with every subscribed event selected.
- No new `data:read` grant: event metadata carries everything the notification
  needs.
- ntfy headers stay purely operator-configured; request events add no default
  tags.

## 1. Request events

### Emission

`Mydia.Events` gains three helpers following the shape of `media_item_added/3`
(`create_event_async/1`, `resource_type: "media_request"`,
`resource_id: request.id`, `category: "requests"`):

| Function | Type | Actor |
| --- | --- | --- |
| `media_request_created(request)` | `media_request.created` | `:user`, the requester |
| `media_request_approved(request, opts)` | `media_request.approved` | `:user` and the approving admin, or `:system` for auto-approval |
| `media_request_rejected(request, opts)` | `media_request.rejected` | `:user`, the rejecting admin |

Metadata (string keys):

- All three: `title`, `year`, `media_type`, `tmdb_id`, `requester` (the
  requester's `display_name`, falling back to `username`), `requester_notes`.
- `approved`: `approved_by` (display name as above, absent for auto-approval),
  `auto` (boolean).
- `rejected`: `approved_by` (the rejecting admin; the schema stores both under
  `approved_by_id`), `rejection_reason`.

Emission sites in `Mydia.MediaRequests`, each only on success and after any
enclosing transaction has committed:

- `create_request/3`, after `Repo.insert/1` succeeds.
- `insert_approval/5`, after the transaction returns `{:ok, ...}`. This covers
  both a newly created item and a request linked to an item already in the
  library.
- `reject_request/2`, on `{:ok, updated_request}`.
- `auto_approve_matching_requests/2`, one event per approved request, after
  the transaction returns `{:ok, approved_list}`. This also covers the
  linked-to-existing sibling approvals that `insert_approval/5` triggers.

The requester and approver must be loaded to fill the names. The helpers take
preloaded structs; call sites preload `:requester` (and `:approved_by` where
relevant) rather than the event helper querying.

### Catalog and visibility

- `media_request.created`, `media_request.approved` and
  `media_request.rejected` join `Mydia.Plugins.Manifest.@event_catalog`. The
  catalog is additive, so existing manifests stay valid.
- `Mydia.Events.Visibility` whitelists types for guests, so guests never see
  these events. Admins and users see them in the activity feed.
- `Mydia.Events.Presentation` gets an entry per type so the activity feed
  renders "Alice requested *Title (2024)*", "Request approved: ...",
  "Request rejected: ..." instead of a generic row. Strings go through gettext.

## 2. Per-instance event selection

### Manifest

`Manifest.@setting_types` gains `events`. A field of this type:

- has no `options`; its choices are the plugin's own `events:subscribe` list;
- may declare `default`, a list that must be a subset of `events:subscribe`;
- may appear at most once per `settings_schema`.

Validation errors use the existing `:invalid_manifest` shape.

### Filtering

`Mydia.Plugins.invoke_plugin/2` keeps only the enabled instances whose
selection contains the event type. A new function computes the selection:

1. the instance's saved list under the field's key, when the key is present
   (an empty list means "nothing");
2. otherwise the field's `default`;
3. otherwise every subscribed event.

A plugin with no `events` field skips the filter entirely and behaves exactly
as today. Filtering happens before `Notifier.Delivery.enqueue/3`, so an
unselected event creates no Oban job.

### Seeding new instances

Every path that creates a plugin instance writes the `events` key with the full
`events:subscribe` list when the manifest declares an `events` field. The plan
must enumerate those paths (operator "add instance", bundled default-instance
creation, any first-enable path) and confirm that upgrading an install does not
re-create an existing default instance, which would silently widen it.

### Grants

The notifier's widened `events:subscribe` is a capability change. The plan must
confirm that bundled reconciliation (`effective_grants/2` via `approve/2`)
re-grants it automatically and the notifier does not land in
`needs_reapproval?/1`. If it would, that is a bug to fix in the same change,
since a bundled plugin the operator never installed by hand cannot ask them to
re-approve.

### UI

`MydiaWeb.PluginSetupComponents.settings_field/1` gets an `events` clause: a
daisyUI `filter` row of `<input type="checkbox" class="btn">` chips, one per
subscribed event, labelled with the `Events.Presentation` title. A hidden input
ensures an all-unchecked submit saves `[]` rather than dropping the key, so
"nothing selected" stays distinguishable from "never saved". The save path in
`MydiaWeb.AdminPluginsLive.Index` stores the value as a list of strings and
rejects values outside `events:subscribe`.

### Notifier manifest

`priv/plugins/webhook_notifier.json` goes to version 1.2.0:

- `events:subscribe`: `media_item.added`, `download.completed`,
  `media_request.created`, `media_request.approved`,
  `media_request.rejected`.
- New first-position field:
  `{"key": "events", "type": "events", "label": "Notify on", "default": ["media_item.added", "download.completed"]}`.
- The description mentions request notifications.
- The custom `body_template` label lists the request placeholders.

## 3. Notification content

`plugins/webhook_notifier/src/lib.rs`:

- `describe/1` gains `media_request.created` → "Requested",
  `media_request.approved` → "Request approved",
  `media_request.rejected` → "Request rejected".
- For `media_request.*` events the title is `Title (Year)` (year omitted when
  absent) and the first body line names the person:
  - created: `Alice requested Title (2024)`, then the requester's notes if any;
  - approved: `Approved Title (2024) for Alice` (`Auto-approved ...` when
    `auto` is true);
  - rejected: `Rejected Title (2024) for Alice`, then the rejection reason.
- Discord uses the same text in `content` and the embed; ntfy uses it as the
  body and the title header. Request events carry no poster (no data read).
- Custom target: `requester`, `requester_notes`, `approved_by`,
  `rejection_reason`, `media_type` and `auto` reach `{{...}}` placeholders
  through the existing metadata flattening in `build_context/3`. Non-string
  scalars follow whatever that function already does for numbers and booleans.
- `read_media/1` stays `media_item`-only.

## Testing

All fixtures use invented titles and names.

- `test/mydia/media_requests_test.exs`: each success path emits exactly one
  event of the right type with the right metadata, including auto-approval and
  approval linked to an existing item; a failed approval (metadata error,
  rolled-back transaction) and a failed rejection emit nothing; cancel emits
  nothing.
- `test/mydia/plugins/manifest_test.exs`: `events` type accepted; `default`
  outside `events:subscribe` rejected; two `events` fields rejected; catalog
  accepts the three request types.
- Plugin dispatch tests (injectable invoker): saved selection honoured; key
  absent falls back to `default`; no `default` means all; empty list means
  none; a plugin without an `events` field is unfiltered; new instances are
  seeded with every subscribed event.
- Bundled reconciliation test: after the manifest bump the notifier is granted
  the new events and not reported by `needs_reapproval?/1`.
- LiveView test on the plugin settings modal: chips render, an all-unchecked
  save stores `[]`, a forged value outside the list is rejected.
- Rust unit tests in the guest: request formatting for ntfy, Discord and
  custom, with and without year, notes and rejection reason.

## Docs

- `docs/plugins/reference/events.md`: the three request events with their
  metadata and the version they appear in.
- `docs/plugins/reference/manifest.md`: the `events` setting type.
- `docs/plugins/how-to/notifications.md`: choosing events per instance and
  setting up request notifications to ntfy.

The WIT `event` record carries the type as a string and metadata as a JSON bag,
so the plugin ABI does not change.

## Out of scope

- Notifying the requester (per-user notification channels).
- Withdrawal (`cancel_request/2`) events.
- Other request-adjacent events (poster updates, auto-approve skips).
