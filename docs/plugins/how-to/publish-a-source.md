# Publish your own plugin source

A plugin source is a signed catalog that Mydia admins can add from
Admin > System > Plugins. Mydia only installs from catalogs signed with
[minisign](https://jedisct1.github.io/minisign/), and it remembers the key it
saw when the admin added your source. Keep that key safe: if you lose it or
change it, every admin has to remove your source and add it again.

## 1. Make a signing key

```bash
minisign -G -p mysource.pub -s mysource.key
```

Back up `mysource.key`. Publish the second line of `mysource.pub` (it starts
with `RW`); that is the public key admins will see.

## 2. Write `index.json`

List each plugin with its package URL, the SHA-256 of the `.wasm` you host
(`sha256sum fixture-tool.wasm`) and its manifest, and put the public key from
step 1 in `public_key`. The fields and rules are in the
[plugin source format](../reference/plugin-source-format.md).

## 3. Sign and host it

```bash
minisign -S -s mysource.key -m index.json
```

Host `index.json` and `index.json.minisig` side by side over https. Re-sign
every time `index.json` changes.

## 4. Tell people how to add it

Give admins the URL and the key fingerprint (`minisign` prints it as the key
id). They can add it in the UI, which shows the fingerprint to compare, or
declare it:

```bash
PLUGINS_SOURCE_0_URL=https://example.com/index.json
PLUGINS_SOURCE_0_PUBLIC_KEY=RW...
```

```yaml
plugin_sources:
  - url: https://example.com/index.json
    public_key: RW...
```

## What operators see

See [Add a third-party plugin source](../../using/how-to/plugin-sources.md).

To test a plugin before publishing, sideload it instead
([test and iterate](test-and-iterate.md)).
