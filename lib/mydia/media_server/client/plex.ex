defmodule Mydia.MediaServer.Client.Plex do
  @moduledoc """
  Plex media server adapter.
  """

  @behaviour Mydia.MediaServer.Client

  alias Mydia.MediaServer.Error

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

    url = build_url(config, "/library/sections/all/refresh")

    params =
      if path do
        [path: path]
      else
        []
      end

    Logger.info("Triggering Plex library scan", server: config.name, path: path)

    url
    |> Req.get(headers: headers(config), params: params)
    |> classify()
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
    url = build_url(config, "/library/sections")

    case Req.get(url, headers: headers(config)) do
      {:ok, %{status: 200, body: body}} ->
        sections =
          get_in(body, ["MediaContainer", "Directory"])
          |> List.wrap()
          |> Enum.map(fn dir ->
            %{key: dir["key"], type: dir["type"], title: dir["title"]}
          end)

        {:ok, sections}

      {:ok, %{status: status}} ->
        {:error, "Failed to list sections: HTTP #{status}"}

      {:error, exception} ->
        {:error, "Failed to list sections: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Lists all items in a library section with GUID metadata.

  Returns items with `ratingKey`, `viewCount`, `lastViewedAt`, and parsed GUIDs.
  """
  def list_section_items(config, section_key) do
    url = build_url(config, "/library/sections/#{section_key}/all")

    case Req.get(url, headers: headers(config), params: [includeGuids: 1]) do
      {:ok, %{status: 200, body: body}} ->
        items =
          get_in(body, ["MediaContainer", "Metadata"])
          |> List.wrap()
          |> Enum.map(fn item ->
            %{
              rating_key: item["ratingKey"],
              title: item["title"],
              type: item["type"],
              view_count: item["viewCount"] || 0,
              last_viewed_at: item["lastViewedAt"],
              guids: parse_guids(item["Guid"])
            }
          end)

        {:ok, items}

      {:ok, %{status: status}} ->
        {:error, "Failed to list section items: HTTP #{status}"}

      {:error, exception} ->
        {:error, "Failed to list section items: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Lists all episodes (leaves) for a show with GUID metadata.

  Returns episodes with `ratingKey`, `viewCount`, season/episode numbers, and parsed GUIDs.
  """
  def list_show_episodes(config, show_rating_key) do
    url = build_url(config, "/library/metadata/#{show_rating_key}/allLeaves")

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
              last_viewed_at: ep["lastViewedAt"],
              guids: parse_guids(ep["Guid"])
            }
          end)

        {:ok, episodes}

      {:ok, %{status: status}} ->
        {:error, "Failed to list show episodes: HTTP #{status}"}

      {:error, exception} ->
        {:error, "Failed to list show episodes: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Marks an item as watched (scrobble) on the Plex server.
  """
  def scrobble(config, rating_key) do
    url = build_url(config, "/:/scrobble")

    params = [
      identifier: "com.plexapp.plugins.library",
      key: rating_key
    ]

    case Req.get(url, headers: headers(config), params: params) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "Scrobble failed: HTTP #{status}"}
      {:error, exception} -> {:error, "Scrobble failed: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Marks an item as unwatched (unscrobble) on the Plex server.
  """
  def unscrobble(config, rating_key) do
    url = build_url(config, "/:/unscrobble")

    params = [
      identifier: "com.plexapp.plugins.library",
      key: rating_key
    ]

    case Req.get(url, headers: headers(config), params: params) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "Unscrobble failed: HTTP #{status}"}
      {:error, exception} -> {:error, "Unscrobble failed: #{Exception.message(exception)}"}
    end
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

  # ── Private Helpers ────────────────────────────────────────────────

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
