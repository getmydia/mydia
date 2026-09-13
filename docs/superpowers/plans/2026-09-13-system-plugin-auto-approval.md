# System Plugin Automatic Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every image-bundled Mydia system plugin start approved and enabled, then automatically refresh its exact capability grant on upgrade without changing an administrator's later enabled/disabled choice.

**Architecture:** Keep `Mydia.Plugins.ensure_bundled/0` as the only system-plugin trust boundary. Reuse one effective-grant calculation from manual approval and bundled reconciliation; persist each bundled manifest and its matching grant in one changeset, then let the existing registration path activate enabled rows. Derive UI pending-approval state from an empty grant rather than from `enabled`, so an approved but disabled plugin exposes Enable instead of Review & approve.

**Tech Stack:** Elixir 1.19, Phoenix LiveView 1.2, Ecto, ExUnit, SQLite/PostgreSQL portability, Wasmex-backed plugin host.

## Global Constraints

- Only manifests discovered from `priv/plugins/*.json` and rows whose persisted `source_url` is exactly `"bundled"` receive automatic approval.
- New bundled plugins are approved and enabled; later reconciliation preserves `enabled` exactly.
- Non-bundled and index-installed plugins keep explicit approval and re-approval.
- Existing settings remain unchanged and determine host-granting `net:http` entries.
- The reconciled grant exactly replaces the old grant, including removal of capabilities no longer declared.
- Manifest metadata and `granted_capabilities` must update in one `PluginConfig` changeset.
- Preserve the current override → DB blob → bundled filesystem artifact resolver and its legacy-byte safety guard.
- Do not add a migration, dependency, generalized trust-policy abstraction, rollback path, or source heuristic.
- Use `./dev mix ...` for Mix commands. Run Git commands through `devenv shell -- git ...`.

---

## File Structure

- `lib/mydia/plugins.ex` — owns bundled discovery/reconciliation, effective grant computation, error isolation, and manual approval reuse.
- `test/mydia/plugins_test.exs` — proves manifest/grant atomicity, exact replacement, settings preservation, enabled-state preservation, and the third-party boundary.
- `test/mydia/plugins/notifier_integration_test.exs` — proves a real shipped plugin is seeded approved, enabled, filesystem-backed, and activated by normal registration.
- `lib/mydia_web/live/admin_plugins_live/index.ex` — derives pending approval from grant state, independently of enabled/disabled runtime state.
- `test/mydia_web/live/admin_plugins_live_test.exs` — proves an approved disabled plugin offers Enable while unapproved third-party rows retain Review & approve.
- `docs/plugins/explanation/plugin-model.md` — explains the source-specific trust model.
- `docs/plugins/reference/manifest.md` — states exact install/upgrade behavior for third-party versus bundled manifests.
- `priv/changelog/0.14.0.md` — records the operator-visible upgrade behavior.

### Task 1: Atomically approve and reconcile bundled plugins

**Files:**
- Modify: `lib/mydia/plugins.ex:223-388, 416-437, 940-958`
- Modify: `test/mydia/plugins_test.exs:427-493`
- Modify: `test/mydia/plugins/notifier_integration_test.exs:35-122`

**Interfaces:**
- Consumes: `Settings.create_plugin_config/1`, `Settings.update_plugin_config/2`, `Manifest.t()`, `manifest_to_map/1`, `put_effective_http/3`, `resolve_artifact/1`, and the existing `register_plugins/0` activation pass.
- Produces: private `effective_grants/2 :: (map(), map() | nil -> map())`; `ensure_bundled/0 :: :ok` remains unchanged publicly.

- [ ] **Step 1: Replace the stale bundled-reconciliation expectations with failing contract tests**

In `test/mydia/plugins_test.exs`, replace the two tests under `describe "ensure_bundled/0 manifest reconciliation"` with tests that exercise the real shipped webhook manifest:

```elixir
test "refreshes manifest and exact effective grant while preserving enabled state and settings" do
  settings = %{
    "target" => "ntfy",
    "webhook_url" => "https://ntfy.example.com/mydia"
  }

  {:ok, _config} =
    Settings.create_plugin_config(%{
      slug: "webhook-notifier",
      name: "Old Notifier",
      version: "1.0.0",
      source_url: "bundled",
      enabled: true,
      granted_capabilities: %{
        "net:http" => ["discord.com"],
        "obsolete" => ["remove-me"]
      },
      settings: settings,
      manifest: %{
        "slug" => "webhook-notifier",
        "name" => "Old Notifier",
        "version" => "1.0.0",
        "capabilities" => %{"net:http" => ["discord.com"]}
      }
    })

  assert :ok = Plugins.ensure_bundled()

  refreshed = Settings.get_plugin_config_by_slug("webhook-notifier")
  expected =
    refreshed.manifest["capabilities"]
    |> Map.put("net:http", ["discord.com", "ntfy.example.com"])

  assert refreshed.enabled
  assert refreshed.settings == settings
  assert refreshed.granted_capabilities == expected
  refute Plugins.needs_reapproval?(refreshed)
end

test "refreshes a disabled bundled plugin grant without enabling it" do
  {:ok, _config} =
    Settings.create_plugin_config(%{
      slug: "webhook-notifier",
      name: "Webhook Notifier",
      version: "1.0.0",
      source_url: "bundled",
      enabled: false,
      granted_capabilities: %{
        "net:http" => ["discord.com"],
        "obsolete" => ["remove-me"]
      },
      settings: %{"delivery" => "durable"},
      manifest: %{
        "slug" => "webhook-notifier",
        "name" => "Webhook Notifier",
        "version" => "1.0.0",
        "capabilities" => %{"net:http" => ["discord.com"]}
      }
    })

  assert :ok = Plugins.ensure_bundled()

  refreshed = Settings.get_plugin_config_by_slug("webhook-notifier")
  refute refreshed.enabled
  assert refreshed.granted_capabilities == refreshed.manifest["capabilities"]
  refute Map.has_key?(refreshed.granted_capabilities, "obsolete")
  refute Plugins.needs_reapproval?(refreshed)
end
```

Keep the existing third-party manifest-revision tests at `test/mydia/plugins_test.exs:260-425`; they prove non-bundled grants still never widen without `Plugins.approve/2`.

In `test/mydia/plugins/notifier_integration_test.exs`, rewrite the first test so real bundled discovery is immediately approved and normal registration activates it:

```elixir
test "R17: the bundled notifier is approved and activated through generic plugin plumbing" do
  assert :ok = Plugins.ensure_bundled()

  config = Settings.get_plugin_config_by_slug(@slug)
  assert config.enabled
  assert config.granted_capabilities == config.manifest["capabilities"]
  assert config.settings["delivery"] == "durable"
  assert config.wasm_module == nil
  assert config.integrity_hash == nil
  refute Plugins.needs_reapproval?(config)

  assert :ok = Plugins.register_plugins()
  assert {:ok, descriptor} = Registry.lookup(@slug)
  assert descriptor.delivery == :durable
  assert descriptor.events == ["media_item.added", "download.completed"]
  assert Host.running?(@slug)
end
```

Rename `"ensure_bundled does not clobber an already-installed notifier"` to `"ensure_bundled does not trust a same-slug non-bundled plugin"` and add assertions that its `source_url`, grant, `enabled`, settings, and version all remain unchanged. Keep the stale-DB-byte test unchanged except for updating its grant expectation to the shipped manifest's exact capabilities.

- [ ] **Step 2: Run the focused tests and confirm the old behavior fails**

Run:

```bash
./dev mix test test/mydia/plugins_test.exs test/mydia/plugins/notifier_integration_test.exs
```

Expected: failures show a new bundled row is disabled with `%{}` grants, an upgraded bundled row retains the obsolete/narrow grant, and `needs_reapproval?/1` remains true after upgrade.

- [ ] **Step 3: Centralize effective grant computation**

In `lib/mydia/plugins.ex`, introduce one private helper beside `put_effective_http/3`:

```elixir
defp effective_grants(manifest_map, settings) do
  manifest_map
  |> Map.get("capabilities", %{})
  |> put_effective_http(manifest_map, settings)
end
```

Use it in `approve/2`:

```elixir
Settings.update_plugin_config(config, %{
  granted_capabilities: effective_grants(manifest, config.settings),
  enabled: true
})
```

Update comments and moduledocs that currently claim bundled grants never auto-expand. Keep the claim scoped to manually installed/index plugins.

- [ ] **Step 4: Seed new bundled plugins approved and enabled in one insert**

Compute settings and the manifest map once, then store their matching grant:

```elixir
defp seed_bundled(manifest, raw) do
  settings = bundled_settings(raw)
  manifest_map = manifest_to_map(manifest)

  attrs = %{
    slug: manifest.slug,
    name: manifest.name,
    version: manifest.version,
    source_url: "bundled",
    integrity_hash: nil,
    manifest: manifest_map,
    wasm_module: nil,
    granted_capabilities: effective_grants(manifest_map, settings),
    enabled: true,
    settings: settings
  }

  case Settings.create_plugin_config(attrs) do
    {:ok, _config} -> :ok
    {:error, reason} -> log_bundled_reconciliation_error(manifest.slug, reason)
  end
end
```

Add the focused logging helper; it must return `:ok` so `Enum.each/2` continues to the next bundled plugin:

```elixir
defp log_bundled_reconciliation_error(slug, reason) do
  Logger.error("plugin #{slug}: could not reconcile bundled configuration: #{inspect(reason)}")
  :ok
end
```

- [ ] **Step 5: Reconcile manifest metadata and exact grants in one update**

Replace `refresh_bundled_manifest/2` with a state reconciliation that uses the persisted settings and preserves `enabled` by omitting it from attrs:

```elixir
defp reconcile_bundled(%Settings.PluginConfig{source_url: "bundled"} = config, manifest) do
  case refresh_bundled_state(config, manifest) do
    {:ok, updated} -> reconcile_bundled_artifact(updated)
    {:error, _reason} -> :ok
  end
end

defp reconcile_bundled(_config, _manifest), do: :ok

defp refresh_bundled_state(config, manifest) do
  manifest_map = manifest_to_map(manifest)

  attrs =
    %{}
    |> put_changed(:manifest, manifest_map, config.manifest)
    |> put_changed(:name, manifest.name, config.name)
    |> put_changed(:version, manifest.version, config.version)
    |> put_changed(
      :granted_capabilities,
      effective_grants(manifest_map, config.settings),
      config.granted_capabilities
    )

  if attrs == %{} do
    {:ok, config}
  else
    case Settings.update_plugin_config(config, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} ->
        log_bundled_reconciliation_error(config.slug, reason)
        {:error, reason}
    end
  end
end
```

Keep `reconcile_bundled_artifact/1` after this update. Do not alter its check that resolves an artifact with `wasm_module: nil` before clearing legacy bytes.

- [ ] **Step 6: Run focused plugin tests**

Run:

```bash
./dev mix test test/mydia/plugins_test.exs test/mydia/plugins/notifier_integration_test.exs
```

Expected: all tests pass. The real notifier is enabled and running after `register_plugins/0`; upgraded bundled grants exactly match the shipped manifest plus settings-derived host; disabled state and non-bundled state are preserved.

- [ ] **Step 7: Commit the plugin lifecycle change**

```bash
devenv shell -- git add lib/mydia/plugins.ex test/mydia/plugins_test.exs test/mydia/plugins/notifier_integration_test.exs
printf '%s\n' 'feat(plugins): auto-approve bundled system plugins' > /tmp/mydia-system-plugin-task1.txt
devenv shell -- git commit -F /tmp/mydia-system-plugin-task1.txt
```

Verify the commit contains all three paths:

```bash
devenv shell -- git show --stat --oneline HEAD
```

### Task 2: Distinguish approval state from enabled state

**Files:**
- Modify: `lib/mydia_web/live/admin_plugins_live/index.ex:355-385`
- Modify: `test/mydia_web/live/admin_plugins_live_test.exs:197-235`

**Interfaces:**
- Consumes: row-local `capabilities` and `granted` maps in `MydiaWeb.AdminPluginsLive.row/1`.
- Produces: `pending_approval` is true only when capabilities are requested and no capability grant exists; no public API changes.

- [ ] **Step 1: Add a failing LiveView behavior test**

Add this test under `describe "capability approval (AE1, R7)"`:

```elixir
test "an approved disabled plugin offers Enable instead of another approval", %{conn: conn} do
  capabilities = manifest_map("notifier", "Notifier")["capabilities"]
  seed_plugin("notifier", "Notifier", enabled: false, granted: capabilities)

  {:ok, view, _} = live(conn, ~p"/admin/plugins")

  assert has_element?(view, "#plugin-row-notifier")
  assert has_element?(view, "#toggle-notifier")
  refute has_element?(view, "#approve-notifier")
  refute has_element?(view, "#reapproval-badge-notifier")
end
```

Do not change the existing pending third-party test: an empty grant must still display `#approve-webhook-notifier` and keep the plugin inactive.

- [ ] **Step 2: Run the test and confirm disabled is misclassified as pending**

Run:

```bash
./dev mix test test/mydia_web/live/admin_plugins_live_test.exs
```

Expected: the new test fails because `pending_approval` currently follows `not config.enabled`, hiding `#toggle-notifier` and showing `#approve-notifier`.

- [ ] **Step 3: Derive pending approval from the grant**

In `MydiaWeb.AdminPluginsLive.row/1`, replace:

```elixir
pending_approval: not config.enabled and capabilities != %{},
```

with:

```elixir
pending_approval: capabilities != %{} and granted == %{},
```

Update the adjacent comment to state that enabled/disabled is a runtime choice after approval, while an empty grant represents pending approval.

- [ ] **Step 4: Run the focused LiveView tests**

Run:

```bash
./dev mix test test/mydia_web/live/admin_plugins_live_test.exs
```

Expected: all tests pass; empty-grant third-party rows still require approval, and approved disabled rows render the lifecycle toggle.

- [ ] **Step 5: Commit the UI state correction**

```bash
devenv shell -- git add lib/mydia_web/live/admin_plugins_live/index.ex test/mydia_web/live/admin_plugins_live_test.exs
printf '%s\n' 'fix(plugins): separate approval from enabled state' > /tmp/mydia-system-plugin-task2.txt
devenv shell -- git commit -F /tmp/mydia-system-plugin-task2.txt
```

Verify both paths landed:

```bash
devenv shell -- git show --stat --oneline HEAD
```

### Task 3: Document and verify the trusted bundled-plugin behavior

**Files:**
- Modify: `docs/plugins/explanation/plugin-model.md:70-107`
- Modify: `docs/plugins/reference/manifest.md:48-98`
- Modify: `priv/changelog/0.14.0.md`

**Interfaces:**
- Consumes: the behavior implemented by Tasks 1 and 2.
- Produces: operator and plugin-author documentation that distinguishes bundled system trust from third-party deny-by-default approval.

- [ ] **Step 1: Rewrite the plugin-model security explanation**

Replace the unconditional “grants never auto-expand” passage with source-specific language containing these exact guarantees:

```markdown
Third-party plugin grants never auto-expand. A plugin installed from an index or
remote package runs only with the capability set an administrator approved, and
a revised manifest that asks for more remains on its old grant until explicit
re-approval.

Image-bundled system plugins are the deliberate exception. They are delivered as
part of the trusted Mydia host release, so discovery grants their complete
shipped capability set and enables a new system plugin. Later host upgrades
replace that grant with the bundled manifest's current effective set, including
settings-derived HTTP hosts. Upgrades preserve whether the administrator has
since enabled or disabled the plugin.
```

Retain the explanation that every host call checks `granted_capabilities`, exact hostname allowlists reject wildcards, and non-bundled capability drift remains visible in the UI and logs. Remove the statement that a bundled-manifest upgrade waits for re-approval.

- [ ] **Step 2: Make the manifest reference explicit**

At the start of “Capabilities,” state that explicit install approval applies to third-party plugins. Replace the “A manifest revision needs a re-approval” warning with two named cases:

```markdown
!!! warning "Third-party manifest revisions need re-approval"
    A plugin installed from an index or remote package cannot widen its grant.
    New capability classes, hosts, or events remain denied until an administrator
    reviews and re-approves the revised manifest.

!!! note "Bundled system plugins follow the host release"
    Plugins shipped in Mydia's `priv/plugins/` directory are trusted as part of
    the host release. First discovery grants and enables them automatically.
    Later releases replace their grants with the exact effective capabilities in
    the shipped manifest while preserving the administrator's enabled/disabled
    choice and settings.
```

- [ ] **Step 3: Add the upgrade note**

Add one concise server/plugin bullet to `priv/changelog/0.14.0.md`:

```markdown
- Plugins shipped with Mydia are approved and enabled on first discovery; later host upgrades refresh their grants but preserve an administrator's enabled/disabled choice. Third-party plugins still require explicit approval.
```

- [ ] **Step 4: Run the complete plugin-focused verification**

Run:

```bash
./dev mix test test/mydia/plugins_test.exs test/mydia/plugins/notifier_integration_test.exs test/mydia_web/live/admin_plugins_live_test.exs
```

Expected: all focused context, integration, and LiveView tests pass.

- [ ] **Step 5: Exercise the actual admin surface**

Start the worktree stack:

```bash
./dev up -d
```

Using the browser tool, sign in with the development credentials `admin` / `adminadmin`, open `/admin/plugins`, and verify:

- shipped plugin rows do not show `Review & approve` or `needs re-approval`;
- newly discovered shipped plugins show active state after boot;
- disabling a shipped plugin changes the row to an Enable action without presenting approval controls.

Re-enable any plugin disabled for this smoke test, then stop the stack:

```bash
./dev down
```

- [ ] **Step 6: Run repository precommit verification**

Run:

```bash
./dev mix precommit
```

Expected: formatting, compilation, linting, and the full configured test suite pass.

- [ ] **Step 7: Commit documentation and any verification formatting**

```bash
devenv shell -- git add docs/plugins/explanation/plugin-model.md docs/plugins/reference/manifest.md priv/changelog/0.14.0.md
devenv shell -- git status --short
printf '%s\n' 'docs(plugins): explain bundled system trust' > /tmp/mydia-system-plugin-task3.txt
devenv shell -- git commit -F /tmp/mydia-system-plugin-task3.txt
```

Verify the commit and clean worktree:

```bash
devenv shell -- git show --stat --oneline HEAD
devenv shell -- git status --short --branch
```

Expected: the documentation commit contains exactly the three documented paths, and the worktree has no tracked modifications.
