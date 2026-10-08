defmodule MydiaWeb.UnrestrictedRouteCrawlTest do
  @moduledoc """
  Every GET route, requested as an account with no access restriction.

  PR #565 made a `Mydia.Accounts.Scope` a required argument on every media
  read. For an unrestricted account the filters are no-ops, so the only way it
  regresses is an auth boundary that never assigns `current_scope`: a raise
  (KeyError, FunctionClauseError), or on the byte endpoints a silent 404 that
  `MydiaWeb.MediaAccess` now reports as a `:missing_scope` telemetry event.
  This crawl fails on any of those.

  Every route is either exercised or listed in `@skipped` with a reason, so a
  new route cannot slip past. Budget: under 5 seconds. One seed, one test, a
  static render per LiveView (no connected mount), and no real byte work.
  Credential variants (API key, media token) live in
  `MydiaWeb.Plugs.ScopeAssignmentTest`; the crawl uses the session cookie,
  which every pipeline accepts.
  """
  use MydiaWeb.ConnCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.CollectionsFixtures
  import Mydia.MediaFixtures

  alias MydiaWeb.MissingScopeProbe

  @skipped %{
    "/health" => "unauthenticated, reads no media",
    "/metrics" => "unauthenticated, reads no media",
    "/setup" => "first-run only; redirects once a user exists",
    "/auth/login" => "unauthenticated",
    "/auth/local/login" => "unauthenticated",
    "/auth/login/totp" => "unauthenticated",
    "/auth/auto-login" => "unauthenticated",
    "/auth/logout" => "ends the session the crawl runs on",
    "/auth/:provider" => "OAuth redirect",
    "/auth/:provider/callback" => "OAuth callback",
    "/player" => "static Flutter shell, reads no media",
    "/player/*path" => "static Flutter shell, reads no media",
    "/admin/errors" => "ErrorTracker's own LiveView",
    "/admin/errors/:id" => "ErrorTracker's own LiveView",
    "/admin/errors/:id/:occurrence_id" => "ErrorTracker's own LiveView",
    "/api/v1/downloads/clients/:id" => "admin config, reads no media",
    "/api/v1/indexers/:id" => "admin config, reads no media",
    "/api/v1/config/:key" => "admin config, reads no media",
    "/api/v1/hls/:session_id/index.m3u8" => "needs a live HLS session",
    "/api/v1/hls/:session_id/:track_id/index.m3u8" => "needs a live HLS session",
    "/api/v1/hls/:session_id/:track_id/:segment" => "needs a live HLS session",
    "/api/v1/hls/:session_id/:segment" => "needs a live HLS session",
    "/api/v1/download/job/:job_id/status" => "needs a transcode job",
    "/api/v1/download/job/:job_id/file" => "needs a transcode job",
    "/admin/remote-access" =>
      "reads no media; its render detects the public IP over the network, which " <>
        "admin_remote_access_live_test.exs disables through global app env",
    "/admin/jobs" => "admin Oban dashboard; Oban is not started in tests"
  }

  # Routes naming a seeded record must render it, not bounce to "/" or 404.
  @must_render [
    "/media/:id",
    "/movies/:id",
    "/tv/:id",
    "/collections/:id",
    "/sections/:id",
    "/api/v1/media/:id"
  ]

  # Static renders only. A review of every `connected?(socket)` branch in the
  # exercised LiveViews found no scoped read that happens only on a connected
  # mount. A LiveView that adds one needs its own connected-mount test.

  defp seed do
    user = user_fixture()
    movie = media_item_fixture(%{type: "movie", title: "Crawl Movie Alpha"})
    show = media_item_fixture(%{type: "tv_show", title: "Crawl Show Beta"})
    episode = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
    {:ok, _} = Mydia.Collections.toggle_favorite(user, movie.id)

    %{
      user: user,
      admin: admin_user_fixture(),
      movie: movie,
      movie_file: media_file_fixture(%{media_item_id: movie.id}),
      show: show,
      episode: episode,
      episode_file: media_file_fixture(%{episode_id: episode.id}),
      collection: collection_fixture(%{user: user}),
      section: smart_collection_fixture(%{user: user})
    }
  end

  defp filled_paths(s) do
    %{
      "/media/:id" => "/media/#{s.movie.id}",
      "/movies/:id" => "/movies/#{s.movie.id}",
      "/tv/:id" => "/tv/#{s.show.id}",
      "/sections/:id" => "/sections/#{s.section.id}",
      "/collections/:id" => "/collections/#{s.collection.id}",
      "/play/:type/:id" => "/play/movie/#{s.movie.id}",
      "/admin/config/*slug" => "/admin/config/general",
      "/api/v1/media/:id" => "/api/v1/media/#{s.movie.id}",
      "/api/v1/playback/movie/:id" => "/api/v1/playback/movie/#{s.movie.id}",
      "/api/v1/playback/episode/:id" => "/api/v1/playback/episode/#{s.episode.id}",
      "/api/v1/playback/file/:id" => "/api/v1/playback/file/#{s.movie_file.id}",
      "/api/v1/media/:id/thumbnails.vtt" => "/api/v1/media/#{s.movie_file.id}/thumbnails.vtt",
      "/api/v1/media/:id/thumbnails.jpg" => "/api/v1/media/#{s.movie_file.id}/thumbnails.jpg",
      "/api/v1/download/:content_type/:id/options" =>
        "/api/v1/download/movie/#{s.movie.id}/options",
      "/api/v1/stream/movie/:id" => "/api/v1/stream/movie/#{s.movie.id}",
      "/api/v1/stream/episode/:id" => "/api/v1/stream/episode/#{s.episode.id}",
      "/api/v1/stream/file/:id" => "/api/v1/stream/file/#{s.movie_file.id}",
      "/api/v1/stream/:id" => "/api/v1/stream/#{s.movie_file.id}",
      "/stream/:token/:filename" => MydiaWeb.StreamLink.path(s.user.id, s.movie_file),
      "/api/v1/stream/:content_type/:id/candidates" =>
        "/api/v1/stream/episode/#{s.episode.id}/candidates",
      "/api/player/v1/subtitles/:type/:id" => "/api/player/v1/subtitles/episode/#{s.episode.id}",
      "/api/player/v1/subtitles/:type/:id/:track" =>
        "/api/player/v1/subtitles/movie/#{s.movie.id}/0",
      # Plugin pages read no media. An unknown slug is enough: the crawl only
      # requires no 5xx and no raise. The two LiveViews redirect or render empty
      # for it, and the frame routes authenticate by frame token rather than
      # session, so they answer 401 without one.
      "/plugins/:slug" => "/plugins/crawl-no-such-plugin",
      "/plugins/:slug/activity" => "/plugins/crawl-no-such-plugin/activity",
      "/plugins/:slug/app" => "/plugins/crawl-no-such-plugin/app",
      "/plugins/:slug/app/*path" => "/plugins/crawl-no-such-plugin/app/index.html"
    }
  end

  defp pipe_through(route) do
    verb = route.verb |> to_string() |> String.upcase()

    case Phoenix.Router.route_info(MydiaWeb.Router, verb, route.path, "example.com") do
      %{pipe_through: pipe_through} -> pipe_through
      :error -> []
    end
  end

  defp get_routes do
    MydiaWeb.Router.__routes__()
    |> Enum.filter(&(&1.verb == :get))
    |> Enum.reject(&String.starts_with?(&1.path, "/dev/"))
  end

  test "every GET route works for an unrestricted account", %{conn: conn} do
    MissingScopeProbe.attach()
    s = seed()
    paths = filled_paths(s)
    as_user = log_in_user(conn, s.user)
    as_admin = log_in_user(conn, s.admin)
    routes = get_routes()

    route_paths = MapSet.new(routes, & &1.path)
    stale = @skipped |> Map.keys() |> Enum.reject(&MapSet.member?(route_paths, &1))
    assert stale == [], "@skipped lists routes that no longer exist: #{inspect(stale)}"

    failures =
      for route <- routes, not Map.has_key?(@skipped, route.path), reduce: [] do
        acc ->
          conn = if :require_admin in pipe_through(route), do: as_admin, else: as_user

          path = Map.get(paths, route.path, route.path)

          if path == route.path and String.contains?(route.path, [":", "*"]) do
            ["#{route.path}: has params but no entry in filled_paths/1" | acc]
          else
            case check(conn, route.path, path) do
              :ok -> acc
              {:error, reason} -> ["#{route.path} (#{path}): #{reason}" | acc]
            end
          end
      end

    assert failures == [], Enum.join(Enum.reverse(failures), "\n")
  end

  defp check(conn, route_path, path) do
    with :ok <- static(conn, route_path, path), do: no_missing_scope()
  end

  defp static(conn, route_path, path) do
    conn = get(conn, path)
    seeded? = route_path in @must_render

    cond do
      conn.status >= 500 ->
        {:error, "status #{conn.status}"}

      seeded? and conn.status not in 200..399 ->
        {:error, "status #{conn.status} for a seeded record"}

      seeded? and redirected_to_root?(conn) ->
        {:error, "bounced to / for a seeded record"}

      true ->
        :ok
    end
  rescue
    error -> {:error, "raised " <> Exception.format_banner(:error, error, __STACKTRACE__)}
  end

  defp redirected_to_root?(conn) do
    conn.status in 300..399 and Plug.Conn.get_resp_header(conn, "location") == ["/"]
  end

  defp no_missing_scope do
    receive do
      {:missing_scope, _metadata} -> {:error, "authorized a media file without a scope"}
    after
      0 -> :ok
    end
  end
end
