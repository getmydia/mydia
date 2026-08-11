defmodule Mydia.MediaServer.Client.Plex do
  @moduledoc """
  Plex media server adapter.
  """

  @behaviour Mydia.MediaServer.Client

  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.Plex.Endpoint

  require Logger

  @impl true
  def test_connection(%{url: nil}), do: {:error, Error.unexpected("URL is required")}
  def test_connection(%{url: ""}), do: {:error, Error.unexpected("URL is required")}
  def test_connection(%{token: nil}), do: {:error, Error.auth("Token is required")}
  def test_connection(%{token: ""}), do: {:error, Error.auth("Token is required")}

  def test_connection(config) do
    # `/library/sections` requires a valid token. `/identity` does NOT: it
    # answers 200 with a garbage token or with no token header at all, which is
    # why it must never be used to validate credentials.
    # Probe directly; do not recurse through Endpoint.resolve/1.
    config
    |> build_url("/library/sections")
    |> Req.get(headers: headers(config), retry: false)
    |> classify()
  end

  @impl true
  def update_library(config, opts \\ []) do
    path = opts[:path]

    # If path is provided, we scan that specific location
    # Endpoint: /library/sections/all/refresh?path=...
    # If no path, we scan all libraries
    # Endpoint: /library/sections/all/refresh

    params =
      if path do
        [path: path]
      else
        []
      end

    Logger.info("Triggering Plex library scan", server: config.name, path: path)

    with_url(config, "/library/sections/all/refresh", fn url ->
      url
      |> Req.get(headers: headers(config), params: params)
      |> classify()
    end)
  end

  defp classify({:ok, %{status: status}}) when status in 200..299, do: :ok

  defp classify({:ok, %{status: status}}) when status in [401, 403],
    do: {:error, Error.auth("HTTP #{status}")}

  defp classify({:ok, %{status: status}}), do: {:error, Error.unexpected("HTTP #{status}")}

  defp classify({:error, %Req.TransportError{} = e}),
    do: {:error, Error.unreachable(Exception.message(e))}

  defp classify({:error, exception}),
    do: {:error, Error.unexpected(Exception.message(exception))}

  # ── Watched Sync API ──────────────────────────────────────────────

  @doc """
  Lists all library sections on the Plex server.

  Returns `{:ok, [%{key: String.t(), type: String.t(), title: String.t()}]}`.
  """
  def list_sections(config) do
    with_url(config, "/library/sections", fn url ->
      case Req.get(url, headers: headers(config)) do
        {:ok, %{status: 200, body: body}} ->
          sections =
            get_in(body, ["MediaContainer", "Directory"])
            |> List.wrap()
            |> Enum.map(fn dir ->
              %{key: dir["key"], type: dir["type"], title: dir["title"]}
            end)

          {:ok, sections}

        other ->
          classify(other)
      end
    end)
  end

  @doc """
  Lists all items in a library section with GUID metadata.

  Returns items with `ratingKey`, `viewCount`, `viewOffset`, `lastViewedAt`,
  and parsed GUIDs.

  ## Options

    * `:start` - `X-Plex-Container-Start` offset (default 0)
    * `:size` - `X-Plex-Container-Size` page length (omit for the server default)
    * `:since` - when set, adds a `lastViewedAt>` filter so Plex only returns
      items viewed at or after that instant
  """
  def list_section_items(config, section_key, opts \\ []) do
    params =
      [includeGuids: 1]
      |> maybe_put_since(opts[:since])

    headers =
      config
      |> headers()
      |> maybe_put_container_header("X-Plex-Container-Start", opts[:start])
      |> maybe_put_container_header("X-Plex-Container-Size", opts[:size])

    with_url(config, "/library/sections/#{section_key}/all", fn url ->
      case Req.get(url, headers: headers, params: params) do
        {:ok, %{status: 200, body: body}} ->
          items =
            get_in(body, ["MediaContainer", "Metadata"])
            |> List.wrap()
            |> Enum.map(&parse_library_item/1)

          {:ok, items}

        other ->
          classify(other)
      end
    end)
  end

  @doc """
  Lists all episodes (leaves) for a show with GUID metadata.

  Returns episodes with `ratingKey`, `viewCount`, season/episode numbers, and parsed GUIDs.
  """
  def list_show_episodes(config, show_rating_key) do
    with_url(config, "/library/metadata/#{show_rating_key}/allLeaves", fn url ->
      case Req.get(url, headers: headers(config), params: [includeGuids: 1]) do
        {:ok, %{status: 200, body: body}} ->
          episodes =
            get_in(body, ["MediaContainer", "Metadata"])
            |> List.wrap()
            |> Enum.map(fn ep ->
              %{
                rating_key: ep["ratingKey"],
                title: ep["title"],
                season_number: ep["parentIndex"],
                episode_number: ep["index"],
                view_count: ep["viewCount"] || 0,
                view_offset: ep["viewOffset"],
                last_viewed_at: ep["lastViewedAt"],
                guids: parse_guids(ep["Guid"])
              }
            end)

          {:ok, episodes}

        other ->
          classify(other)
      end
    end)
  end

  @doc """
  Marks an item as watched (scrobble) on the Plex server.
  """
  def scrobble(config, rating_key) do
    params = [
      identifier: "com.plexapp.plugins.library",
      key: rating_key
    ]

    with_url(config, "/:/scrobble", fn url ->
      case Req.get(url, headers: headers(config), params: params) do
        {:ok, %{status: 200}} -> :ok
        other -> classify(other)
      end
    end)
  end

  @doc """
  Marks an item as unwatched (unscrobble) on the Plex server.
  """
  def unscrobble(config, rating_key) do
    params = [
      identifier: "com.plexapp.plugins.library",
      key: rating_key
    ]

    with_url(config, "/:/unscrobble", fn url ->
      case Req.get(url, headers: headers(config), params: params) do
        {:ok, %{status: 200}} -> :ok
        other -> classify(other)
      end
    end)
  end

  @doc """
  Parses Plex GUID entries into a map of external IDs.

  Plex returns GUIDs like `[%{"id" => "tmdb://12345"}, %{"id" => "imdb://tt1234567"}]`.

  Returns `%{tmdb: "12345", imdb: "tt1234567", tvdb: "67890"}` (only present keys).
  """
  def parse_guids(nil), do: %{}

  def parse_guids(guids) when is_list(guids) do
    Enum.reduce(guids, %{}, fn guid, acc ->
      case guid["id"] do
        "tmdb://" <> id -> Map.put(acc, :tmdb, id)
        "imdb://" <> id -> Map.put(acc, :imdb, id)
        "tvdb://" <> id -> Map.put(acc, :tvdb, id)
        _ -> acc
      end
    end)
  end

  def parse_guids(_), do: %{}

  defp parse_library_item(item) do
    %{
      rating_key: item["ratingKey"],
      title: item["title"],
      type: item["type"],
      view_count: item["viewCount"] || 0,
      view_offset: item["viewOffset"],
      last_viewed_at: item["lastViewedAt"],
      guids: parse_guids(item["Guid"])
    }
  end

  defp maybe_put_since(params, nil), do: params

  defp maybe_put_since(params, %DateTime{} = since) do
    Keyword.put(params, :"lastViewedAt>", DateTime.to_unix(since))
  end

  defp maybe_put_container_header(headers, _name, nil), do: headers

  defp maybe_put_container_header(headers, name, value) when is_integer(value) do
    headers ++ [{name, Integer.to_string(value)}]
  end

  # ── Private Helpers ────────────────────────────────────────────────

  # Every request resolves an endpoint rather than trusting a stored address.
  defp with_url(config, path, fun) do
    case Endpoint.resolve(config) do
      {:ok, base} ->
        result = fun.(String.trim_trailing(base, "/") <> path)

        # A working endpoint that just failed at the transport layer is stale.
        if match?({:error, %Error{kind: :unreachable}}, result), do: Endpoint.invalidate(config)

        result

      {:error, _} = err ->
        err
    end
  end

  defp build_url(config, path) do
    base = String.trim_trailing(config.url, "/")
    "#{base}#{path}"
  end

  defp headers(config) do
    [
      {"X-Plex-Token", config.token},
      {"Accept", "application/json"}
    ]
  end
end
