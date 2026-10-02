# Extra plugins

Plugins here are published to the official index at
`https://plugins.mydia.dev/index.json` and installed by operators from
Admin > System > Plugins. They are **not** part of the Mydia image.

Their settings can also come from the environment, for example for the
Assistant:

```bash
PLUGIN_0_SLUG=assistant-openai
PLUGIN_0_SETTINGS='{"base_url":"https://api.openai.com/v1","api_key":"sk-...","model":"gpt-4.1-mini","shelf_model":"gpt-4.1-nano"}'
```

`shelf_enabled` (`On` or `Off`) and `shelf_model` control the Assistant's Picked for you suggestions.

`plugins/` is different: the `:plugins` Mix compiler builds every
`plugins/*/Cargo.toml` into `priv/plugins/`, and those ship bundled and
auto-enabled. Nothing under `plugins-extra/` is compiled by Mix or by the nix
package, so an extra plugin needs no nix vendoring block.

## Layout

Each plugin is its own cargo crate:

    plugins-extra/<crate>/
      Cargo.toml       # cdylib, depends on ../../native/mydia_plugin_sdk
      Cargo.lock
      manifest.json    # the plugin manifest (docs/plugins/reference/manifest.md)
      src/lib.rs

The crate directory name must match the built artifact name
(`target/wasm32-wasip2/release/<crate>.wasm`).

## Publishing

Bump `version` in `manifest.json`, merge, then push a tag:

    git tag plugins-v2026.10.1 && git push origin plugins-v2026.10.1

`.github/workflows/plugins-publish.yml` builds and tests every crate here with
the toolchain from `rust-toolchain.toml`, generates the index with
`scripts/build_plugin_index.exs`, deploys it to the `mydia-plugins` Cloudflare
Pages project, and attaches the packages to a GitHub Release for the tag.

Every publish replaces the whole site, so only the current version of each
plugin is downloadable. Installed plugins are unaffected: their bytes live in
the database.
