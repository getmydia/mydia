# Plugin source format

A plugin source is a JSON catalog (`index.json`) plus a minisign signature file
(`index.json.minisig`). Mydia fetches both, verifies the signature against the
key it pinned for the source, then lists the plugins in the catalog. To build and
host one, see [Publish a plugin source](../how-to/publish-a-source.md).

## Catalog

```json
{
  "version": 2,
  "name": "Example Plugins",
  "public_key": "RWT...",
  "plugins": [
    {
      "package_url": "https://example.com/packages/fixture-tool/1.0.0.wasm",
      "integrity": "sha256:<hex sha256 of the .wasm file>",
      "manifest": { "...": "the plugin's manifest" }
    }
  ]
}
```

### Top-level fields

| Field | Required | Rules |
|-------|----------|-------|
| `version` | no | The catalog format version. The scripted index builder writes `2`. Mydia does not read it. |
| `name` | no | Display name of the source. When missing, Mydia shows the host of the source URL. |
| `public_key` | yes, to add the source | The minisign public key the catalog is signed with: the key line of the `.pub` file, starting `RW`. Adding a source in the UI previews it from this field, and a catalog without a valid one cannot be previewed. On later fetches, a value that differs from the key already pinned reports a key change (see [Signature](#signature)). |
| `plugins` | yes | Array of [entries](#entry-fields). A catalog without a `plugins` array lists nothing. |

The catalog must be a JSON object and valid JSON, or it is rejected.

### Entry fields

| Field | Required | Rules |
|-------|----------|-------|
| `package_url` | yes | `https` URL of the `.wasm` package. A non-empty string. |
| `integrity` | yes | SHA-256 of the package. See [Integrity](#integrity). |
| `manifest` | yes | The plugin's full [manifest](manifest.md). It is validated with the same rules as any manifest. |
| `slug`, `name`, `version`, `description`, `author` | no | Ignored. Mydia takes all of these from the embedded `manifest`. The scripted index builder copies them to the entry for readers of the file. |

An entry is dropped without failing the catalog when it is not an object, lacks a
non-empty `package_url` or `integrity`, or carries an invalid manifest. Mydia logs
a warning on the server and shows nothing to the operator, so a mistake in one
entry makes that plugin quietly absent.

The embedded manifest is what the operator sees at approval, before the package
is downloaded.

## Integrity

`integrity` is the SHA-256 of the exact `.wasm` bytes you host, as lowercase or
uppercase hex. Both forms are accepted:

- `sha256:<hex>`
- `<hex>`

Mydia recomputes the hash after downloading the package. A mismatch rejects the
package with an `integrity_mismatch` error before it is registered or activated.
The signature covers the catalog, so it covers every `integrity` value, and so
ties each package to your key.

## Signature

- The signature file is the catalog URL with `.minisig` appended:
  `https://example.com/index.json` is verified against
  `https://example.com/index.json.minisig`. Host the two side by side.
- Both minisign signature algorithms are accepted: the legacy `Ed` and the
  prehashed `ED`, which is the default of current `minisign`.
- Mydia pins a source's key when an operator adds it. The Sources card and the
  add dialog show the key's fingerprint: the key id, 16 uppercase hex digits, as
  `minisign` prints it. Operators compare it with the one you publish.
- If the catalog later names a different `public_key` than the pinned one, the
  source reports `key_changed` and nothing is installed from it until the
  operator removes and re-adds the source. A key change is never accepted in
  place.
- Re-sign every time `index.json` changes.

The official index is the exception to pinning: its key is compiled into Mydia.

## Transport and size

- The catalog URL, the signature URL and every `package_url` must be `https`.
  Other schemes are refused.
- Every fetch goes through the outbound gate, which also refuses private
  addresses.
- A package may be at most 32 MiB. See [limits](limits.md#packages).

## Replay

The format has no timestamp or counter, and Mydia does not check freshness. A
host that serves you can replay an older signed catalog. Installed plugins are
protected, because Mydia only treats a version as an update when it is newer than
the installed one. A fresh install may get an older listed version.

## How the catalog is used

- A plugin installed from a source takes updates only from that source. Slugs
  already installed from another origin are listed as replaceable, and
  installing one is an explicit replace that moves its updates to the new source.
- A slug that belongs to a plugin bundled with Mydia cannot be replaced from a
  source.
- A source can be declared in config (`plugin_sources`) or by environment
  variable. See the
  [configuration reference](../../using/reference/configuration.md).
