defmodule Mydia.Indexers.Cardigann.Wasm.Codec do
  @moduledoc """
  Converts between Mydia's plain Elixir shapes and the Wasmex values of the
  `mydia:cardigann/engine` world, as recorded in `native/cardigann_guest/SPIKE.md`
  ("Wasmex value shapes").

  Arguments are built with kebab-case atom keys and `:none | {:some, v}`
  options. Results are read through `field/2`, which accepts an atom or a
  string key because Wasmex returns an atom only when the atom already exists
  in the VM.
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.QualityParser
  alias Mydia.Indexers.SearchResult

  @type session :: %{cookies: %{String.t() => String.t()}, expires_at: DateTime.t() | nil}
  @type query :: %{
          kind: :search | :movie | :tv,
          term: String.t(),
          categories: [integer()],
          imdb_id: String.t() | nil,
          tmdb_id: integer() | nil,
          tvdb_id: integer() | nil,
          season: integer() | nil,
          episode: String.t() | nil,
          limit: integer() | nil,
          offset: integer() | nil
        }
  @type captcha_answer :: %{answer: String.t(), state: String.t()}

  # ── Arguments ─────────────────────────────────────────────────────────────

  @doc "A query record for the `search` export."
  @spec encode_query(query()) :: map()
  def encode_query(q) do
    %{
      kind: q.kind,
      term: q.term,
      categories: q.categories,
      "imdb-id": option(q.imdb_id),
      "tmdb-id": option(q.tmdb_id),
      "tvdb-id": option(q.tvdb_id),
      season: option(q.season),
      episode: option(q.episode),
      limit: option(q.limit),
      offset: option(q.offset)
    }
  end

  @doc "Settings as name/value records, sorted by name."
  @spec encode_settings(%{String.t() => String.t()}) :: [map()]
  def encode_settings(settings) do
    settings
    |> Enum.sort()
    |> Enum.map(fn {name, value} -> %{name: to_string(name), value: to_string(value)} end)
  end

  @spec encode_session(session()) :: map()
  def encode_session(%{cookies: cookies, expires_at: expires_at}) do
    %{
      cookies: cookies |> Enum.sort() |> Enum.map(fn {n, v} -> %{name: n, value: v} end),
      "expires-unix": option(expires_at && DateTime.to_unix(expires_at))
    }
  end

  @doc "The `option<captcha-answer>` argument of `login`."
  @spec encode_captcha_answer(captcha_answer() | nil) :: :none | {:some, map()}
  def encode_captcha_answer(nil), do: :none
  def encode_captcha_answer(%{answer: a, state: s}), do: {:some, %{answer: a, state: s}}

  # ── Results ───────────────────────────────────────────────────────────────

  @spec decode_session(map()) :: session()
  def decode_session(session) do
    cookies =
      session
      |> field(:cookies)
      |> List.wrap()
      |> Map.new(fn c -> {field(c, :name), field(c, :value)} end)

    expires_at =
      case session |> field(:"expires-unix") |> unoption() do
        nil -> nil
        unix -> DateTime.from_unix!(unix)
      end

    %{cookies: cookies, expires_at: expires_at}
  end

  @doc "A `search-out` record."
  @spec decode_search(map(), String.t()) :: %{
          releases: [SearchResult.t()],
          session: session(),
          session_changed: boolean()
        }
  def decode_search(out, indexer_name) do
    %{
      releases:
        out |> field(:releases) |> List.wrap() |> Enum.map(&decode_release(&1, indexer_name)),
      session: out |> field(:session) |> decode_session(),
      session_changed: field(out, :"session-changed") == true
    }
  end

  @doc "A `download-out` record."
  @spec decode_download(map()) :: %{
          payload: {:bytes, binary()} | {:link, String.t()},
          session: session()
        }
  def decode_download(out) do
    payload =
      case field(out, :payload) do
        {:bytes, bytes} -> {:bytes, bytes_to_binary(bytes)}
        {:link, link} -> {:link, link}
      end

    %{payload: payload, session: out |> field(:session) |> decode_session()}
  end

  @doc "A `login-out` variant."
  @spec decode_login({:ok, map()} | {:captcha, map()}) ::
          {:ok, session()}
          | {:captcha, %{image: binary(), content_type: String.t(), state: String.t()}}
  def decode_login({:ok, session}), do: {:ok, decode_session(session)}

  def decode_login({:captcha, challenge}) do
    {:captcha,
     %{
       image: challenge |> field(:image) |> bytes_to_binary(),
       content_type: field(challenge, :"content-type"),
       state: field(challenge, :state)
     }}
  end

  @doc """
  A `release` record as a `SearchResult`. `leechers` is `peers - seeders`
  (Prowlarr's `Peers` includes the seeders), and a magnet-only release uses the
  magnet as its download URL.
  """
  @spec decode_release(map(), String.t()) :: SearchResult.t()
  def decode_release(release, indexer_name) do
    title = field(release, :title)
    seeders = release |> field(:seeders) |> unoption()
    peers = release |> field(:peers) |> unoption()
    magnet = release |> field(:"magnet-url") |> unoption()
    download_url = release |> field(:"download-url") |> unoption() || magnet
    publish_unix = release |> field(:"publish-unix") |> unoption()

    SearchResult.new(
      title: title,
      size: release |> field(:size) |> unoption() |> Kernel.||(0),
      seeders: seeders,
      leechers: leechers(seeders, peers),
      download_url: download_url,
      info_url: release |> field(:"info-url") |> unoption(),
      indexer: indexer_name,
      category: release |> field(:categories) |> List.wrap() |> List.first(),
      published_at: publish_unix && DateTime.from_unix!(publish_unix),
      quality: QualityParser.parse(title),
      tmdb_id: release |> field(:"tmdb-id") |> unoption(),
      tvdb_id: release |> field(:"tvdb-id") |> unoption(),
      imdb_id: release |> field(:"imdb-id") |> unoption(),
      download_protocol: :torrent,
      guid: field(release, :guid)
    )
  end

  defp leechers(seeders, peers) when is_integer(seeders) and is_integer(peers),
    do: max(peers - seeders, 0)

  defp leechers(_seeders, _peers), do: nil

  @doc "Maps an `engine-error` variant onto `Mydia.Indexers.Adapter.Error`."
  @spec decode_error(term()) :: Error.t()
  def decode_error({:login_failed, message}), do: Error.authentication_failed(message)
  def decode_error({:captcha_required, message}), do: Error.captcha_required(message)
  def decode_error({:request_limit, message}), do: Error.rate_limited(message)

  def decode_error({:cloudflare, message}),
    do: Error.api_error("Cloudflare protection: " <> message, %{cloudflare: true})

  def decode_error({:parse_failed, message}), do: Error.parse_error(message)
  def decode_error({:http, message}), do: Error.network_error(message)
  def decode_error({:internal, message}), do: Error.engine_error(message)
  def decode_error(other), do: Error.engine_error("Unrecognised engine error: #{inspect(other)}")

  # ── Helpers ───────────────────────────────────────────────────────────────

  @doc false
  def field(map, key) when is_map(map) do
    case map do
      %{^key => value} -> value
      _ -> Map.get(map, Atom.to_string(key))
    end
  end

  defp option(nil), do: :none
  defp option(value), do: {:some, value}

  defp unoption({:some, value}), do: value
  defp unoption(_none_or_nil), do: nil

  defp bytes_to_binary(bytes) when is_list(bytes), do: :erlang.list_to_binary(bytes)
  defp bytes_to_binary(bytes) when is_binary(bytes), do: bytes
end
