defmodule Mydia.Plugins.Index do
  @moduledoc """
  Plugin index/source catalogs and package integrity (U7, R11–R13).

  An **index** (or custom **source**) is a JSON catalog listing available
  plugins; a **package** is a compiled `wasm32` module fetched from a catalog
  entry's `package_url` and verified against the entry's declared integrity hash
  before it is ever registered or activated (R12, AE4).

  ## Trust model

  Every catalog is signed with minisign (`index.json.minisig` beside
  `index.json`). The official index's key is compiled in from
  `priv/plugin_index/official.pub`; a third-party source's key is pinned when an
  admin adds it (`Mydia.Plugins.Sources`) or declared with it in env/YAML. The
  signature covers each entry's package `integrity` hash, so verifying the
  catalog and then the package hash proves the bytes came from the key holder.

  HTTPS and the SSRF gate (`Mydia.Plugins.Net.Gate`) still apply to every fetch.
  A key change is never accepted in-band: the source reports `:key_changed`
  until an admin removes and re-adds it. Only sideloading accepts unsigned code.

  ## Catalog format

      {
        "version": 2,
        "name": "My Plugins",
        "public_key": "RWT…",
        "plugins": [
          {
            "slug": "webhook-notifier",
            "name": "Webhook Notifier",
            "version": "1.0.0",
            "description": "...",
            "author": "Mydia",
            "package_url": "https://.../webhook_notifier.wasm",
            "integrity": "sha256:ab12…",
            "manifest": { …full plugin manifest… }
          }
        ]
      }
  """

  require Logger

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Index.BrowseResult
  alias Mydia.Plugins.Index.CatalogItem
  alias Mydia.Plugins.Index.Entry
  alias Mydia.Plugins.Index.Signature
  alias Mydia.Plugins.Index.Source
  alias Mydia.Plugins.Index.SourcePreview
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Net.Gate
  alias Mydia.Plugins.Sources

  @official_key_path Path.expand("../../../priv/plugin_index/official.pub", __DIR__)
  @external_resource @official_key_path
  @official_public_key @official_key_path |> File.read!() |> String.trim()

  # Packages are larger than a typical API response; allow more headroom than the
  # gate's default cap, but still bounded.
  @package_max_bytes 33_554_432

  @doc "The configured official index URL (R13 default)."
  @spec official_index_url() :: String.t()
  def official_index_url, do: config().index_url

  @doc """
  The official index as a source. Its key is compiled in unless `index_url` is
  overridden, in which case config validation required `index_public_key`.
  Nil when `index_url` is blank.
  """
  @spec official_source() :: Source.t() | nil
  def official_source do
    cfg = config()
    override = Map.get(cfg, :index_public_key)
    key_text = if blank?(override), do: @official_public_key, else: override

    with false <- blank?(cfg.index_url),
         {:ok, key} <- Signature.parse_public_key(key_text) do
      %Source{url: cfg.index_url, name: "Mydia", public_key: key, official?: true}
    else
      _ -> nil
    end
  end

  @doc "The official index first, then every enabled `plugin_sources` row."
  @spec sources() :: [Source.t()]
  def sources do
    rows =
      Enum.flat_map(Sources.enabled_sources(), fn row ->
        case Signature.parse_public_key(row.public_key) do
          {:ok, key} ->
            [
              %Source{
                id: row.id,
                url: row.url,
                name: row.name || URI.parse(row.url).host,
                public_key: key
              }
            ]

          {:error, _} ->
            []
        end
      end)

    Enum.reject([official_source() | rows], &is_nil/1)
  end

  @doc """
  Fetches a catalog, verifies its signature against the source's pinned key and
  parses it into a list of `%Entry{}`.

  Routes through the SSRF gate and rejects non-https sources. Each entry's
  embedded manifest is validated; a listing with an invalid manifest is dropped
  (logged) rather than failing the whole catalog. The outcome is recorded on the
  source's row when it has one.
  """
  @spec fetch_catalog(Source.t(), keyword()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def fetch_catalog(%Source{} = source, opts \\ []) do
    result =
      with :ok <- require_https(source.url, opts),
           {:ok, body} <- gate_get(source.url, opts),
           {:ok, json} <- decode_json(body, "catalog"),
           :ok <- same_embedded_key(json, source.public_key),
           {:ok, minisig} <- gate_get(source.url <> ".minisig", opts),
           :ok <- Signature.verify(body, minisig, source.public_key) do
        {:ok, json, parse_entries(json, source)}
      end

    case result do
      {:ok, json, entries} ->
        Sources.record_fetch(
          source.id,
          {:ok, %{name: json["name"], plugin_count: length(entries)}}
        )

        {:ok, entries}

      {:error, error} ->
        Sources.record_fetch(source.id, {:error, describe_error(error)})
        {:error, error}
    end
  end

  @doc """
  Fetches the catalog at `url` and verifies it against the key it embeds, so the
  admin can see what adding it would pin (name, key fingerprint, plugin count).
  """
  @spec preview_source(String.t(), keyword()) :: {:ok, SourcePreview.t()} | {:error, Error.t()}
  def preview_source(url, opts \\ []) do
    url = String.trim(url)

    with :ok <- require_https(url, opts),
         {:ok, body} <- gate_get(url, opts),
         {:ok, json} <- decode_json(body, "catalog"),
         {:ok, key} <- embedded_key(json),
         {:ok, minisig} <- gate_get(url <> ".minisig", opts),
         :ok <- Signature.verify(body, minisig, key) do
      source = %Source{url: url, name: json["name"] || URI.parse(url).host, public_key: key}

      {:ok,
       %SourcePreview{
         url: url,
         name: source.name,
         public_key: key.encoded,
         fingerprint: Signature.fingerprint(key),
         plugin_count: length(parse_entries(json, source))
       }}
    end
  end

  @doc "Which origin a catalog entry belongs to, comparable with `Sources.origin/1`."
  @spec entry_origin(Entry.t()) :: :official | {:source, binary()}
  def entry_origin(%Entry{source_id: nil}), do: :official
  def entry_origin(%Entry{source_id: id}), do: {:source, id}

  defp embedded_key(%{"public_key" => text}) when is_binary(text) do
    case Signature.parse_public_key(text) do
      {:ok, key} ->
        {:ok, key}

      {:error, _} ->
        {:error, Error.new(:signature_invalid, "catalog public_key is not a minisign key")}
    end
  end

  defp embedded_key(_json),
    do: {:error, Error.new(:signature_invalid, "catalog does not publish a signing key")}

  # The embedded key is advisory, but when it names a different key the
  # publisher rotated and the admin must re-add the source to trust it.
  defp same_embedded_key(json, pinned) do
    case embedded_key(json) do
      {:ok, %{key_id: id, key: key} = embedded} when id != pinned.key_id or key != pinned.key ->
        {:error,
         Error.new(
           :key_changed,
           "signing key changed (catalog now names key #{Signature.fingerprint(embedded)})"
         )}

      _ ->
        :ok
    end
  end

  @doc """
  Fetches every source and returns each listed plugin as a `CatalogItem`,
  classified against `installed`: anything carrying `:slug`, `:version`,
  `:source_url` and `:plugin_source_id`, normally the admin page's installed
  rows.

  A failing source records the first error message but does not discard the
  entries of sources that answered. `opts` accepts `:sources` (overrides
  `sources/0`); the rest is passed to `fetch_catalog/2`.
  """
  @spec browse([map()], keyword()) :: BrowseResult.t()
  def browse(installed, opts \\ []) do
    {sources, fetch_opts} = Keyword.pop_lazy(opts, :sources, &sources/0)
    installed_by_slug = Map.new(installed, &{&1.slug, &1})

    {entries, error, failed} =
      Enum.reduce(sources, {[], nil, 0}, fn source, {acc, err, failed} ->
        case fetch_catalog(source, fetch_opts) do
          {:ok, found} -> {acc ++ found, err, failed}
          {:error, reason} -> {acc, err || describe_error(reason), failed + 1}
        end
      end)

    %BrowseResult{
      catalog: Enum.map(entries, &catalog_item(&1, Map.get(installed_by_slug, &1.slug))),
      status: browse_status(entries),
      error: error,
      failed_count: failed,
      source_count: length(sources)
    }
  end

  @doc """
  Fetches `entry`'s package and verifies its integrity hash.

  Returns `{:ok, %{wasm: binary, hash: hex}}` on a match, or
  `{:error, %Error{type: :integrity_mismatch}}` if the recomputed hash does not
  equal the declared one (AE4) — the package is rejected before it can be
  registered or activated.
  """
  @spec fetch_package(Entry.t(), keyword()) ::
          {:ok, %{wasm: binary(), hash: String.t()}} | {:error, Error.t()}
  def fetch_package(%Entry{package_url: url, integrity: declared}, opts \\ []) do
    with :ok <- require_https(url, opts),
         {:ok, wasm} <- gate_get(url, Keyword.put_new(opts, :max_bytes, @package_max_bytes)) do
      verify_integrity(wasm, declared)
    end
  end

  @doc """
  Recomputes the SHA-256 of `bytes` and compares it (case-insensitively) to the
  `declared` hash, which may be bare hex or prefixed `sha256:…`.
  """
  @spec verify_integrity(binary(), String.t()) ::
          {:ok, %{wasm: binary(), hash: String.t()}} | {:error, Error.t()}
  def verify_integrity(bytes, declared) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    expected = normalize_hash(declared)

    if actual == expected do
      {:ok, %{wasm: bytes, hash: actual}}
    else
      {:error,
       Error.new(
         :integrity_mismatch,
         "package hash #{actual} does not match declared #{expected}"
       )}
    end
  end

  @doc """
  True when `candidate` is a newer version than `current`, which counts as
  oldest when `nil`. Uses semver when both parse, falling back to string
  comparison.
  """
  @spec version_newer?(String.t(), String.t() | nil) :: boolean()
  def version_newer?(_candidate, nil), do: true

  def version_newer?(candidate, current) do
    case {Version.parse(candidate), Version.parse(current)} do
      {{:ok, c}, {:ok, cur}} -> Version.compare(c, cur) == :gt
      _ -> candidate != current and candidate > current
    end
  end

  # ── Fetch via the SSRF gate ───────────────────────────────────────────────

  defp gate_get(url, opts) do
    host = URI.parse(url).host

    gate_opts =
      [allowed_hosts: [host], slug: "plugin-index"] ++
        Keyword.take(opts, [:allow_private, :resolver, :max_bytes, :timeout])

    case Gate.request(url, gate_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, Error.new(:network_error, "source returned HTTP #{status}")}

      {:error, _} = err ->
        err
    end
  end

  # ── Parsing ───────────────────────────────────────────────────────────────

  defp decode_json(body, what) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, Error.new(:invalid_config, "#{what} is not a JSON object")}
      {:error, _} -> {:error, Error.new(:invalid_config, "#{what} is not valid JSON")}
    end
  end

  defp parse_entries(%{"plugins" => plugins}, source) when is_list(plugins) do
    plugins
    |> Enum.map(&parse_entry(&1, source))
    |> Enum.flat_map(fn
      {:ok, entry} ->
        [entry]

      {:error, error} ->
        Logger.warning("dropping invalid catalog entry from #{source.url}: #{inspect(error)}")
        []
    end)
  end

  defp parse_entries(_, _), do: []

  defp parse_entry(%{} = raw, source) do
    with {:ok, package_url} <- fetch_required(raw, "package_url"),
         {:ok, integrity} <- fetch_required(raw, "integrity"),
         {:ok, manifest} <- Manifest.parse(Map.get(raw, "manifest", %{})) do
      {:ok,
       %Entry{
         slug: manifest.slug,
         name: manifest.name,
         version: manifest.version,
         description: manifest.description,
         author: manifest.author,
         package_url: package_url,
         integrity: integrity,
         manifest: manifest,
         source_url: source.url,
         source_id: source.id,
         source_name: source.name
       }}
    end
  end

  defp parse_entry(_, _),
    do: {:error, Error.new(:invalid_config, "catalog entry must be an object")}

  defp fetch_required(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:invalid_config, "catalog entry missing #{key}")}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp browse_status([]), do: :empty
  defp browse_status(_entries), do: :available

  defp catalog_item(entry, nil), do: %CatalogItem{entry: entry, state: :not_installed}

  defp catalog_item(entry, installed) do
    state = install_state(entry, installed)

    %CatalogItem{
      entry: entry,
      state: state,
      installed_version: installed.version,
      installed_from:
        if(state == :other_source, do: Sources.origin_name(Sources.origin(installed)))
    }
  end

  # A store version usually lives at a new, versioned package URL, so origin is
  # decided by `Sources.origin/1`, not by the package URL.
  defp install_state(entry, installed) do
    case Sources.origin(installed) do
      :bundled -> :bundled
      :sideloaded -> :replace
      origin -> version_state(origin == entry_origin(entry), entry, installed)
    end
  end

  defp version_state(false, _entry, _installed), do: :other_source

  defp version_state(true, entry, installed) do
    cond do
      entry.version == installed.version -> :installed
      version_newer?(entry.version, installed.version) -> :update
      true -> :replace
    end
  end

  defp describe_error(%{__exception__: true} = error), do: Exception.message(error)
  defp describe_error(other), do: inspect(other)

  # HTTPS is the v1 trust anchor; the `:allow_private` test seam (loopback Bypass)
  # also relaxes the scheme check, matching the gate's seam.
  defp require_https(url, opts) do
    cond do
      Keyword.get(opts, :allow_private, false) -> :ok
      URI.parse(url).scheme == "https" -> :ok
      true -> {:error, Error.new(:invalid_config, "source URL must be https: #{url}")}
    end
  end

  defp normalize_hash(declared) do
    declared
    |> String.trim()
    |> String.replace_prefix("sha256:", "")
    |> String.downcase()
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp config do
    case Application.get_env(:mydia, :runtime_config) do
      %{plugins: %{} = plugins} -> plugins
      _ -> Mydia.Config.Schema.defaults().plugins
    end
  end
end
