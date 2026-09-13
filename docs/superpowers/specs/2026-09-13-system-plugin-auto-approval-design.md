# System Plugin Automatic Approval Design

## Problem

Mydia ships trusted WebAssembly system plugins in `priv/plugins/`. The host already treats these plugins differently from index-installed plugins: `Mydia.Plugins.ensure_bundled/0` discovers their manifests, stores `source_url: "bundled"`, and resolves their artifacts from the release image. Despite that provenance, newly bundled plugins start disabled with no grants, and a bundled manifest that adds capabilities enters the same manual approval flow as a third-party plugin.

This makes a host upgrade incomplete until an administrator visits Admin > System > Plugins and approves software that was already delivered as part of the trusted Mydia release. System plugins should instead receive the capabilities shipped with that release automatically.

## Goals

- Automatically approve every plugin shipped in `priv/plugins/`, including its first installation and later manifest upgrades.
- Enable a newly discovered bundled plugin by default.
- Preserve an administrator's enabled or disabled choice during later reconciliations.
- Keep settings and settings-derived HTTP grants correct across upgrades.
- Preserve explicit approval and re-approval for every non-bundled plugin.
- Keep bundled manifest, grant, and display metadata consistent in one database update.

## Non-goals

- Trusting plugins because of author, slug, package index, signature, or display metadata.
- Automatically approving plugins installed from the official index or any remote URL.
- Forcing a previously disabled bundled plugin back on.
- Adding a general approval-policy framework or a new database provenance field.
- Adding artifact rollback or changing the existing Wasm resolver.

## Trust Boundary

Only filesystem discovery by `Mydia.Plugins.ensure_bundled/0` confers system-plugin trust. A row is eligible for later automatic reconciliation only when its persisted `source_url` is exactly `"bundled"`.

A same-slug row from any other source is left unchanged. The design must not infer trust from manifest fields such as `author`, from a known slug, or from membership in a remote index. This keeps the existing deny-by-default boundary intact for third-party code.

## Reconciliation Architecture

`ensure_bundled/0` remains the sole reconciliation entry point. For each valid manifest discovered under `priv/plugins/*.json`, it performs one of two transitions.

### New bundled plugin

Create one `PluginConfig` row containing:

- manifest name, version, and complete manifest;
- `source_url: "bundled"`;
- bundled default settings, including delivery mode;
- effective granted capabilities computed from the manifest and those settings;
- `enabled: true`;
- no database Wasm bytes or integrity hash, preserving filesystem-backed artifact resolution.

The row must not exist transiently as pending approval.

### Existing bundled plugin

If the existing row has `source_url: "bundled"`, reconcile it in one changeset:

- refresh changed name, version, and manifest fields;
- replace `granted_capabilities` with the newly computed effective grant;
- preserve `enabled` exactly;
- preserve operator settings, priority, scheduler bookkeeping, and updater metadata;
- retain the existing artifact cleanup behavior described below.

Grant replacement is exact rather than additive. Capabilities removed from the shipped manifest are removed from the grant; capabilities added by the release are granted. Canonically equivalent capability lists must remain equivalent regardless of ordering.

If the existing row is not bundled, reconciliation does nothing to it.

## Effective Capability Calculation

Automatic approval must use the same effective-capability semantics as manual approval. In particular, configurable `net:http` hosts are derived from the current plugin settings rather than blindly copied from the raw manifest.

The implementation should extract the existing calculation behind `approve/2` into a focused private helper and reuse it from both manual approval and bundled reconciliation. This avoids a second grant convention and ensures future fixes apply to both paths.

For a new plugin, the calculation uses bundled default settings. For an existing plugin, it uses the administrator's persisted settings.

## Activation and Runtime Flow

Reconciliation persists state; normal plugin registration remains responsible for activation.

- A new bundled plugin is created enabled and is activated during the same normal registration pass.
- An enabled bundled plugin remains enabled after an upgrade and activates with the refreshed grant and bundled artifact.
- A disabled bundled plugin receives the refreshed grant but remains inactive.
- A non-bundled plugin continues through the existing manual approval, enable, revoke, and re-approval paths.

The Plugins page therefore has no pending-approval or needs-reapproval state for a successfully reconciled bundled plugin. A disabled bundled plugin still offers the normal enable action. Third-party plugins retain their current badges, approval modal, and review controls.

## Artifact Handling

The layered artifact resolver remains unchanged: override directory, database blob, then bundled filesystem artifact.

Older installations may have a bundled plugin's Wasm bytes stored in the database. Reconciliation must retain the current guard that clears those stale bytes only when a replacement artifact resolves without them. If the filesystem artifact is absent, the legacy database bytes remain available and an error is logged. Automatic grant changes must not weaken that guard.

## Error Handling

Failures are isolated per bundled plugin so one bad package does not prevent reconciliation of the others.

- Invalid manifests are skipped and logged with their path.
- Create or update failures are logged with the plugin slug and actionable reason.
- A missing replacement artifact preserves legacy database bytes and follows the existing logging path.
- Activation failures use the existing activation/status reporting. They do not silently fall back to obsolete Wasm or revert the persisted enabled choice.

The manifest metadata and effective grant must be persisted together. A database failure must not leave a refreshed manifest with an old grant, or a refreshed grant with an old manifest.

## Security Model and Documentation

The current documentation says grants never auto-expand. That guarantee becomes source-specific:

- Third-party plugins never auto-expand their grants. Installation and capability expansion require administrator approval.
- Image-bundled Mydia system plugins are part of the trusted host release. Installing or upgrading the host automatically grants the exact capability set declared by those bundled manifests.

The plugin-model explanation and manifest reference must state this exception explicitly. They must also state that disabling a system plugin remains an administrator-controlled runtime choice and is preserved across upgrades.

## Verification

Focused context tests must prove:

1. A newly discovered bundled plugin is created with its full effective grant and enabled.
2. A bundled manifest upgrade adds and removes capabilities without `needs_reapproval?/1` becoming true.
3. Reconciliation preserves `enabled: true` for an enabled bundled plugin.
4. Reconciliation preserves `enabled: false` for a disabled bundled plugin while refreshing its grant.
5. Persisted settings remain unchanged and still determine configurable HTTP grants.
6. A same-slug non-bundled config remains untouched.
7. A missing filesystem replacement preserves legacy database artifact bytes.
8. Third-party installation and manifest expansion still require explicit approval.

Admin LiveView tests should change only where they currently expect approval controls for bundled rows. Existing assertions for third-party approval behavior remain.

Verification commands:

- focused plugin context tests;
- focused admin Plugins LiveView tests;
- `./dev mix precommit`.

## Acceptance Criteria

- Starting a release containing a new bundled plugin creates it approved and enabled without administrator action.
- Starting a release containing a changed bundled manifest updates the plugin's exact effective grant without showing a re-approval requirement.
- Upgrades never change an existing bundled plugin's enabled/disabled choice.
- Existing plugin settings survive reconciliation and remain authoritative for configurable hosts.
- Non-bundled plugins retain the current explicit approval security boundary.
- Reconciliation failures are visible and isolated; no partial manifest/grant update is persisted.
- No migration, new trust-policy abstraction, or resolver behavior change is introduced.
