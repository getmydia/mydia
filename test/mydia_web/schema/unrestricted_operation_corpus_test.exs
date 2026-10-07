defmodule MydiaWeb.Schema.UnrestrictedOperationCorpusTest do
  @moduledoc """
  Every query and mutation the Flutter player ships, run over `/api/graphql`
  as an account with no access restriction.

  The corpus is `player/lib/graphql/{queries,mutations}`, so it is exactly what
  real clients send. Each operation is either run (with variables from
  `variables/1`) or listed in `@skipped` with a reason; an operation in
  neither fails the test, so a new player operation cannot slip past.

  Any GraphQL error fails the run unless `@expected_errors` lists that
  operation with the exact message and a reason unrelated to scope. Budget:
  under 5 seconds, one seed, one test.
  """
  use MydiaWeb.ConnCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias MydiaWeb.MissingScopeProbe

  @graphql_dir Path.expand("../../../player/lib/graphql", __DIR__)

  @skipped %{
    "Login" => "authentication flow, runs before any scope exists",
    "VerifyTotp" => "authentication flow, runs before any scope exists",
    "RefreshMediaToken" => "token flow, reads no media",
    "RefreshAccessToken" => "token flow, reads no media",
    "SubtitleSearch" => "calls an external subtitle provider",
    "DownloadSubtitle" => "calls an external subtitle provider",
    "StartStreamingSession" => "starts ffmpeg; covered by streaming_access_test.exs",
    "EndStreamingSession" => "needs a live streaming session",
    "PrepareDownload" => "starts a transcode job",
    "DownloadJobStatus" => "needs a transcode job",
    "CancelDownloadJob" => "needs a transcode job",
    "RegisterDeviceNode" => "device management, reads no media",
    "RevokeDevice" => "device management, reads no media"
  }

  # operation name => exact error message expected with seeded data, and why.
  @expected_errors %{}

  # `<Op>NoIds` documents are the same operation minus the external-id fields,
  # so they take exactly the variables of `<Op>`.
  @no_ids_ops ~w(CollectionItems HomeRows UnwatchedListing FavoritesListing
                 MydiaContinueWatching RecentlyAddedFull Search)

  defp variables(s) do
    base = base_variables(s)

    Enum.reduce(@no_ids_ops, base, fn op, acc ->
      Map.put(acc, op <> "NoIds", Map.fetch!(base, op))
    end)
  end

  defp base_variables(s) do
    %{
      "TvShowDetail" => %{"id" => s.show.id},
      "EpisodeDetail" => %{"id" => s.episode.id},
      "NowPlayingEpisode" => %{"id" => s.episode.id},
      "NowPlayingMovie" => %{"id" => s.movie.id},
      "Devices" => %{},
      "OnlineDevices" => %{},
      "DevicesList" => %{},
      "ServerCompatibility" => %{},
      "MovieSegments" => %{"id" => s.movie.id},
      "EpisodeSegments" => %{"id" => s.episode.id},
      "MovieSubtitlePreference" => %{"id" => s.movie.id},
      "EpisodeSubtitlePreference" => %{"id" => s.episode.id},
      "Search" => %{"query" => "Crawl", "first" => 5},
      "MydiaInstanceIdentity" => %{},
      "MydiaContinueWatching" => %{"first" => 10},
      "Calendar" => %{"start" => "2000-01-01", "end" => "2100-01-01"},
      "Collections" => %{"first" => 10},
      "CollectionItems" => %{"collectionId" => s.collection.id, "first" => 10},
      "HomeRows" => %{"recentlyAddedLimit" => 10, "favoritesLimit" => 10},
      "MoviesFiltered" => %{
        "first" => 10,
        "sort" => %{"field" => "TITLE", "direction" => "ASC"}
      },
      "TvShowsFiltered" => %{
        "first" => 10,
        "sort" => %{"field" => "TITLE", "direction" => "ASC"}
      },
      "UnwatchedListing" => %{"first" => 10},
      "FavoritesListing" => %{"first" => 10},
      "RecentlyAddedFull" => %{"first" => 10},
      "SeasonEpisodes" => %{"showId" => s.show.id, "seasonNumber" => 1},
      "MovieDetail" => %{"id" => s.movie.id},
      "MovieMediaInfo" => %{"id" => s.movie.id},
      "EpisodeMediaInfo" => %{"id" => s.episode.id},
      "StreamingCandidates" => %{"contentType" => "movie", "id" => s.movie.id},
      "SubtitleContent" => %{"mediaFileId" => s.movie_file.id, "trackId" => "0"},
      "SubtitleTrackSettings" => %{"mediaFileId" => s.movie_file.id},
      "DownloadOptions" => %{"contentType" => "movie", "id" => s.movie.id},
      "SetAudioLanguagePreference" => %{"fileId" => s.movie_file.id, "language" => "eng"},
      "SetSubtitlePreference" => %{"fileId" => s.movie_file.id, "mode" => "OFF"},
      "SetSubtitleOffset" => %{
        "mediaFileId" => s.movie_file.id,
        "trackRef" => "0",
        "offsetMs" => 250
      },
      "ToggleFavorite" => %{"mediaItemId" => s.movie.id},
      "RemoveFromContinueWatching" => %{"mediaItemId" => s.movie.id},
      "UpdateMovieProgress" => %{
        "movieId" => s.movie.id,
        "positionSeconds" => 10,
        "durationSeconds" => 100
      },
      "UpdateEpisodeProgress" => %{
        "episodeId" => s.episode.id,
        "positionSeconds" => 10,
        "durationSeconds" => 100
      },
      "MarkMovieWatched" => %{"movieId" => s.movie.id},
      "MarkMovieUnwatched" => %{"movieId" => s.movie.id},
      "MarkEpisodeWatched" => %{"episodeId" => s.episode.id},
      "MarkEpisodeUnwatched" => %{"episodeId" => s.episode.id},
      "MarkSeasonWatched" => %{"showId" => s.show.id, "seasonNumber" => 1},
      "MarkSeasonUnwatched" => %{"showId" => s.show.id, "seasonNumber" => 1}
    }
  end

  defp seed do
    movie = media_item_fixture(%{type: "movie", title: "Crawl Movie Alpha"})
    show = media_item_fixture(%{type: "tv_show", title: "Crawl Show Beta"})
    episode = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

    user = user_fixture()

    %{
      user: user,
      collection: Mydia.CollectionsFixtures.collection_fixture(%{user: user}),
      movie: movie,
      movie_file: media_file_fixture(%{media_item_id: movie.id}),
      show: show,
      episode: episode,
      episode_file: media_file_fixture(%{episode_id: episode.id})
    }
  end

  # [{operation_name, document}], queries before mutations, each document
  # carrying only the shared fragments it spreads (transitively).
  defp operations do
    fragments =
      for file <- Path.wildcard(Path.join(@graphql_dir, "fragments/*.graphql")), into: %{} do
        source = File.read!(file)
        [_, name] = Regex.run(~r/^fragment\s+(\w+)/m, source)
        {name, source}
      end

    for dir <- ["queries", "mutations"],
        file <- Path.wildcard(Path.join([@graphql_dir, dir, "*.graphql"])),
        source = File.read!(file),
        [name] <- Regex.scan(~r/^(?:query|mutation)\s+(\w+)/m, source, capture: :all_but_first) do
      {name, with_fragments(source, fragments)}
    end
  end

  defp with_fragments(source, fragments) do
    needed = needed_fragments(source, fragments, MapSet.new())
    Enum.join([source | Enum.map(needed, &Map.fetch!(fragments, &1))], "\n")
  end

  defp needed_fragments(source, fragments, acc) do
    ~r/\.\.\.\s*(\w+)/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&(Map.has_key?(fragments, &1) and not MapSet.member?(acc, &1)))
    |> Enum.reduce(acc, fn name, acc ->
      needed_fragments(Map.fetch!(fragments, name), fragments, MapSet.put(acc, name))
    end)
  end

  test "every player operation works for an unrestricted account", %{conn: conn} do
    MissingScopeProbe.attach()
    s = seed()
    vars = variables(s)
    as_user = log_in_user(conn, s.user)
    ops = operations()

    assert length(ops) >= 40, "corpus not found under #{@graphql_dir}"

    names = MapSet.new(ops, &elem(&1, 0))

    stale =
      (Map.keys(@skipped) ++ Map.keys(vars))
      |> Enum.reject(&MapSet.member?(names, &1))

    assert stale == [], "listed operations no longer in the corpus: #{inspect(stale)}"

    failures =
      for {name, document} <- ops, not Map.has_key?(@skipped, name), reduce: [] do
        acc ->
          case Map.fetch(vars, name) do
            :error -> ["#{name}: no entry in variables/1 or @skipped" | acc]
            {:ok, variables} -> run(as_user, name, document, variables) ++ acc
          end
      end

    assert failures == [], Enum.join(Enum.reverse(failures), "\n")
  end

  defp run(conn, name, document, variables) do
    conn =
      post(conn, "/api/graphql", %{
        "query" => document,
        "operationName" => name,
        "variables" => variables
      })

    body = json_response(conn, 200)
    expected = Map.get(@expected_errors, name)

    errors =
      body
      |> Map.get("errors", [])
      |> Enum.map(& &1["message"])
      |> Enum.reject(&(&1 == expected))

    scope_gap =
      receive do
        {:missing_scope, _} -> ["#{name}: authorized a media file without a scope"]
      after
        0 -> []
      end

    Enum.map(errors, &"#{name}: #{&1}") ++ scope_gap
  rescue
    error -> ["#{name}: raised " <> Exception.format_banner(:error, error, __STACKTRACE__)]
  end
end
