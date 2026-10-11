defmodule MydiaWeb.SearchLive.ReleaseAdd do
  @moduledoc """
  Socket-free add path for a release grabbed on /search.

  Split out of the LiveView to keep it under the size ratchet and so the
  release-title-to-media-item pipeline can be tested without a LiveView.
  """

  alias Mydia.Library.ReleaseParser, as: FileParser
  alias Mydia.Media
  alias Mydia.Media.AddDefaults
  alias Mydia.Media.RemoteFilter
  alias Mydia.Metadata
  alias Mydia.Metadata.Ref

  require Logger

  # `media_type` is the user's choice in the download modal and overrides the
  # parser's guess, which is what the metadata search and the created item's
  # type both follow. Before #1104 the choice was collected and dropped.
  def add_release_to_library(scope, title, media_type, defaults) do
    Logger.info("Adding release to library as #{media_type}: #{title}")

    with {:ok, parsed} <- parse_release_title(title, media_type),
         {:ok, metadata_or_matches} <- search_and_fetch_metadata(scope, parsed) do
      case metadata_or_matches do
        {:multiple_matches, matches, matched_type} ->
          # Return the matches to trigger disambiguation in the UI
          {:ok, {:needs_disambiguation, parsed, matches, matched_type}}

        metadata ->
          # Single match, create media item directly
          create_media_item_from_metadata(scope, parsed, metadata, defaults: defaults)
      end
    end
  end

  # The chosen type is applied before the unknown check, so a release the
  # parser cannot classify still adds once the user picked Movie or TV.
  defp parse_release_title(title, media_type) do
    parsed = %{FileParser.parse(title) | type: media_type}

    Logger.debug(
      "Parsed release: type=#{parsed.type}, title=#{parsed.title}, " <>
        "year=#{parsed.year}, season=#{parsed.season}, " <>
        "episodes=#{inspect(parsed.episodes)}, confidence=#{parsed.confidence}"
    )

    cond do
      parsed.type in [:unknown, nil] or blank?(parsed.title) ->
        {:error, :parse_failed}

      parsed.confidence < 0.5 ->
        Logger.warning("Low confidence parse (#{parsed.confidence}), may not be accurate")
        {:ok, parsed}

      true ->
        {:ok, parsed}
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  @doc false
  # Public only so the restricted auto-match branches can be pinned in tests.
  def search_and_fetch_metadata(scope, parsed) do
    # Use the default metadata relay configuration
    config = Metadata.default_relay_config()

    # Determine media type for the search
    media_type =
      case parsed.type do
        :movie -> :movie
        :tv_show -> :tv_show
        _ -> :movie
      end

    # Search for the media
    search_opts = [media_type: media_type]
    search_opts = if parsed.year, do: [{:year, parsed.year} | search_opts], else: search_opts

    # A restricted account must not match a release to a title outside its
    # limits. The branch is chosen on the raw hit count, though: a release
    # that was ambiguous stays ambiguous, so the account confirms the pick
    # instead of having the one survivor linked automatically.
    search_result =
      with {:ok, matches} <- Metadata.search(config, parsed.title, search_opts) do
        {:ok, length(matches), RemoteFilter.filter(matches, scope)}
      end

    case search_result do
      {:ok, _raw_count, []} ->
        Logger.warning("No metadata matches found for: #{parsed.title}")
        {:error, :no_metadata_match}

      {:ok, 1, [single_match]} ->
        # Only one match, fetch it directly
        Logger.info("Found single metadata match: #{single_match.title || single_match.name}")

        fetch_full_metadata(config, single_match, media_type)

      {:ok, _raw_count, matches} ->
        # Multiple matches, return them for disambiguation
        Logger.info("Found #{length(matches)} metadata matches, requires disambiguation")
        {:ok, {:multiple_matches, matches, media_type}}

      {:error, reason} ->
        Logger.error("Metadata search failed: #{inspect(reason)}")
        {:error, {:metadata_error, "Search failed"}}
    end
  end

  def fetch_full_metadata(config, match, media_type) do
    # `match` is the search result the id came from, so its own provenance
    # (`:tmdb` or `:tvdb`) names the provider, rather than guessing from
    # media_type.
    ref = Ref.from_search_result(match)

    case Metadata.fetch_by_ref(config, ref, media_type: media_type) do
      {:ok, metadata} ->
        {:ok, metadata}

      {:error, reason} ->
        Logger.error("Failed to fetch full metadata: #{inspect(reason)}")
        {:error, {:metadata_error, "Failed to fetch details"}}
    end
  end

  @doc """
  Creates (or finds the existing) media item for already-fetched metadata.

  Public, like `MediaLive.Show.FranchiseEvents.perform_add/5`, so it can be
  exercised directly in tests without driving a real metadata fetch through
  `start_async/3`.

  `opts` takes `defaults: %AddDefaults{}`, the settings chosen in the download
  modal; without it the user's own defaults apply. Returns whether the item was
  `:created` or was `:existing` in the library already.
  """
  def create_media_item_from_metadata(scope, parsed, metadata, opts \\ []) do
    # Check if media already exists by provider ID, scoped by type: TMDB numbers
    # movies and series independently, so a movie's tmdb_id is not this show's.
    # For TV shows from TVDB, check tvdb_id; otherwise check tmdb_id.
    provider_key =
      if parsed.type == :tv_show and Map.get(metadata, :provider) == :tvdb do
        :tvdb
      else
        :tmdb
      end

    existing =
      Media.find_by_external_ids(scope, %{provider_key => metadata.provider_id},
        type: to_string(parsed.type)
      )

    case existing do
      nil ->
        # Create new media item
        # `from_parsed` reads :defaults with Keyword.get_lazy, so a nil value
        # would be used as-is; leave the key out instead.
        attr_opts =
          [user: scope.user] ++ if(opts[:defaults], do: [defaults: opts[:defaults]], else: [])

        attrs = Mydia.Media.AttrsFromMetadata.from_parsed(parsed, metadata, attr_opts)

        # Episodes are automatically fetched for TV shows via create_media_item
        case Media.create_media_item(scope, attrs) do
          {:ok, media_item} ->
            {:ok, media_item, :created}

          {:error, :restricted} ->
            {:error, :restricted}

          {:error, changeset} ->
            Logger.error("Failed to create media item: #{inspect(changeset.errors)}")
            {:error, {:create_failed, changeset.errors}}
        end

      existing_item ->
        Logger.info("Media already exists in library: #{existing_item.title}")
        {:ok, existing_item, :existing}
    end
  end

  def extract_search_hint(release_title) do
    # Try to extract a reasonable search query from the release title
    # Remove common release tags and patterns
    release_title
    |> String.replace(
      ~r/\b(720p|1080p|2160p|4k|WEB-?DL|BluRay|HDTV|x264|x265|HEVC|AAC|DTS)\b/i,
      ""
    )
    |> String.replace(~r/\b(S\d{1,2}E\d{1,2})\b/i, "")
    |> String.replace(~r/\b(\d{4})\b/, "")
    |> String.replace(~r/[\.\-_]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc false
  # Public for tests. A newly created item downloads into the library the
  # user chose; an item already in the library keeps its own.
  def download_opts(media_item_id, :created, %AddDefaults{library_path_id: lib})
      when is_binary(lib),
      do: [media_item_id: media_item_id, library_path_id: lib]

  def download_opts(media_item_id, _status, _defaults), do: [media_item_id: media_item_id]
end
