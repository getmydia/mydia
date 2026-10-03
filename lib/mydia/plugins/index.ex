defmodule Mydia.Plugins.Index do
  @moduledoc """
  Plugin index/source catalogs and package integrity (U7, R11–R13).

  An **index** (or custom **source**) is a JSON catalog listing available
  plugins; a **package** is a compiled `wasm32` module fetched from a catalog
  entry's `package_url` and verified against the entry's declared integrity hash
  before it is ever registered or activated (R12, AE4).

  ## Trust model (KTD10)

  The catalog declares both the package URL and its hash, so the checksum proves
  *transit* integrity, not authorship. v1 leans on:

    * **Mandatory HTTPS.** Source URLs are validated to be `https` at config time
      (`Mydia.Config.Schema`); this module refuses any non-https URL again at
      fetch time as defence in depth.
    * **The SSRF gate.** Every catalog and package fetch is routed through
      `Mydia.Plugins.Net.Gate`, so a source resolving to a private IP is refused
      exactly like a plugin's own egress would be.

  Cryptographic signing against a developer key is the deferred hardening.

  ## Catalog format

      {
        "version": 1,
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
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Net.Gate

  # Packages are larger than a typical API response; allow more headroom than the
  # gate's default cap, but still bounded.
  @package_max_bytes 33_554_432

  @doc "The configured official index URL (R13 default)."
  @spec official_index_url() :: String.t()
  def official_index_url, do: config().index_url

  @doc """
  All configured source URLs: the official index plus any admin-added custom
  sources (R13).
  """
  @spec sources() :: [String.t()]
  def sources do
    cfg = config()
    [cfg.index_url | cfg.extra_source_urls] |> Enum.reject(&blank?/1) |> Enum.uniq()
  end

  @doc """
  Fetches and parses a catalog from `source_url` into a list of `%Entry{}`.

  Routes through the SSRF gate and rejects non-https sources. Each entry's
  embedded manifest is validated; a listing with an invalid manifest is dropped
  (logged) rather than failing the whole catalog.
  """
  @spec fetch_catalog(String.t(), keyword()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def fetch_catalog(source_url, opts \\ []) do
    with :ok <- require_https(source_url, opts),
         {:ok, body} <- gate_get(source_url, opts),
         {:ok, json} <- decode_json(body, "catalog") do
      {:ok, parse_entries(json, source_url)}
    end
  end

  @doc """
  Fetches every source and returns each listed plugin as a `CatalogItem`,
  classified against `installed`: anything carrying `:slug`, `:version` and
  `:source_url`, normally the admin page's installed rows.

  A failing source records the first error message but does not discard the
  entries of sources that answered. `opts` accepts `:sources` (overrides
  `sources/0`); the rest is passed to `fetch_catalog/2`.
  """
  @spec browse([map()], keyword()) :: BrowseResult.t()
  def browse(installed, opts \\ []) do
    {sources, fetch_opts} = Keyword.pop_lazy(opts, :sources, &sources/0)
    installed_by_slug = Map.new(installed, &{&1.slug, &1})

    {entries, error} =
      Enum.reduce(sources, {[], nil}, fn source, {acc, err} ->
        case fetch_catalog(source, fetch_opts) do
          {:ok, found} -> {acc ++ found, err}
          {:error, reason} -> {acc, err || describe_error(reason)}
        end
      end)

    %BrowseResult{
      catalog: Enum.map(entries, &catalog_item(&1, Map.get(installed_by_slug, &1.slug))),
      status: browse_status(entries),
      error: error,
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

  defp parse_entries(%{"plugins" => plugins}, source_url) when is_list(plugins) do
    plugins
    |> Enum.map(&parse_entry(&1, source_url))
    |> Enum.flat_map(fn
      {:ok, entry} ->
        [entry]

      {:error, error} ->
        Logger.warning("dropping invalid catalog entry from #{source_url}: #{inspect(error)}")
        []
    end)
  end

  defp parse_entries(_, _), do: []

  defp parse_entry(%{} = raw, source_url) do
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
         source_url: source_url
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
    %CatalogItem{
      entry: entry,
      state: install_state(entry, installed),
      installed_version: installed.version
    }
  end

  # A store version usually lives at a new, versioned package URL, so "installed
  # from an index" is anything that is neither bundled nor sideloaded.
  defp install_state(_entry, %{source_url: "bundled"}), do: :bundled

  defp install_state(entry, %{source_url: source_url, version: version}) do
    cond do
      sideloaded?(source_url) -> :replace
      entry.version == version -> :installed
      version_newer?(entry.version, version) -> :update
      true -> :replace
    end
  end

  defp sideloaded?("file://" <> _), do: true
  defp sideloaded?(_source_url), do: false

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
