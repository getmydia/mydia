defmodule MetadataRelay.Router do
  @moduledoc """
  HTTP router for the metadata relay service.
  """

  use Plug.Router
  require Logger

  alias MetadataRelay.TMDB.Handler
  alias MetadataRelay.TVDB.Handler, as: TVDBHandler
  alias MetadataRelay.Music.Handler, as: MusicHandler
  alias MetadataRelay.OpenLibrary.Handler, as: OpenLibraryHandler
  alias MetadataRelay.OpenSubtitles.Handler, as: SubtitlesHandler
  alias MetadataRelay.Pairing.Handler, as: PairingHandler
  alias MetadataRelay.Trakt.Client, as: TraktClient
  alias MetadataRelay.Trakt.Handler, as: TraktHandler

  @feedback_param_atoms %{
    "type" => :type,
    "message" => :message,
    "contact" => :contact,
    "instance_id" => :instance_id,
    "mydia_version" => :mydia_version
  }

  plug(Plug.Logger)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason)
  plug(MetadataRelay.Plug.Cache)
  plug(:match)
  plug(:dispatch)

  # Health check endpoint
  get "/health" do
    response = %{
      status: "ok",
      service: "metadata-relay",
      version: MetadataRelay.version()
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  # Cache statistics endpoint
  get "/stats" do
    cache_stats = MetadataRelay.Cache.stats()

    response = %{
      service: "metadata-relay",
      version: MetadataRelay.version(),
      cache: cache_stats
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  # Prometheus Metrics
  get "/metrics" do
    metrics = MetadataRelay.Metrics.format()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  # TMDB Configuration
  get "/configuration" do
    handle_tmdb_request(conn, fn -> Handler.configuration() end)
  end

  # TMDB Movie Search
  get "/tmdb/movies/search" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.search_movies(params) end)
  end

  # TMDB TV Search
  get "/tmdb/tv/search" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.search_tv(params) end)
  end

  # TMDB Trending Movies (must come before /tmdb/movies/:id)
  get "/tmdb/movies/trending" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.trending_movies(params) end)
  end

  # TMDB Popular Movies
  get "/tmdb/movies/popular" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.popular_movies(params) end)
  end

  # TMDB Upcoming Movies
  get "/tmdb/movies/upcoming" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.upcoming_movies(params) end)
  end

  # TMDB Now Playing Movies
  get "/tmdb/movies/now_playing" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.now_playing_movies(params) end)
  end

  # TMDB Trending TV (must come before /tmdb/tv/shows/:id)
  get "/tmdb/tv/trending" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.trending_tv(params) end)
  end

  # TMDB Popular TV
  get "/tmdb/tv/popular" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.popular_tv(params) end)
  end

  # TMDB On The Air TV
  get "/tmdb/tv/on_the_air" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.on_the_air_tv(params) end)
  end

  # TMDB Airing Today TV
  get "/tmdb/tv/airing_today" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.airing_today_tv(params) end)
  end

  # TMDB Discover Movies (with genre/year/language/rating filters)
  get "/tmdb/movies/discover" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.discover_movies(params) end)
  end

  # TMDB Discover TV
  get "/tmdb/tv/discover" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.discover_tv(params) end)
  end

  # TMDB Movie Genre List
  get "/tmdb/genre/movie" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.genre_movie_list(params) end)
  end

  # TMDB TV Genre List
  get "/tmdb/genre/tv" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.genre_tv_list(params) end)
  end

  # TMDB User List (must come before /tmdb/movies/:id)
  get "/tmdb/list/:id" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_list(id, params) end)
  end

  # TMDB Collection Details (franchise metadata)
  get "/tmdb/collections/:id" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_collection(id, params) end)
  end

  # TMDB Movie Details
  get "/tmdb/movies/:id" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_movie(id, params) end)
  end

  # TMDB TV Show Details
  get "/tmdb/tv/shows/:id" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_tv_show(id, params) end)
  end

  # TMDB Movie Images
  get "/tmdb/movies/:id/images" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_movie_images(id, params) end)
  end

  # TMDB TV Show Images
  get "/tmdb/tv/shows/:id/images" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_tv_images(id, params) end)
  end

  # TMDB TV Season Details
  get "/tmdb/tv/shows/:id/:season" do
    params = extract_query_params(conn)
    handle_tmdb_request(conn, fn -> Handler.get_season(id, season, params) end)
  end

  # TVDB Search
  get "/tvdb/search" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.search(params) end)
  end

  # TVDB Series Details
  get "/tvdb/series/:id" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_series(id, params) end)
  end

  # TVDB Series Extended Details
  get "/tvdb/series/:id/extended" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_series_extended(id, params) end)
  end

  # TVDB Series Episodes
  get "/tvdb/series/:id/episodes" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_series_episodes(id, params) end)
  end

  # TVDB Season Details
  get "/tvdb/seasons/:id" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_season(id, params) end)
  end

  # TVDB Season Extended Details
  get "/tvdb/seasons/:id/extended" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_season_extended(id, params) end)
  end

  # TVDB Episode Details
  get "/tvdb/episodes/:id" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_episode(id, params) end)
  end

  # TVDB Episode Extended Details
  get "/tvdb/episodes/:id/extended" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_episode_extended(id, params) end)
  end

  # TVDB Artwork
  get "/tvdb/artwork/:id" do
    params = extract_query_params(conn)
    handle_tvdb_request(conn, fn -> TVDBHandler.get_artwork(id, params) end)
  end

  # Crash Report Ingestion
  post "/crashes/report" do
    handle_crash_report(conn)
  end

  # Feedback Ingestion
  post "/feedback" do
    handle_feedback(conn)
  end

  # Subtitle Search
  post "/api/v1/subtitles/search" do
    params = extract_body_params(conn)
    handle_subtitles_request(conn, fn -> SubtitlesHandler.search(params) end)
  end

  # Subtitle Download URL
  get "/api/v1/subtitles/download-url/:id" do
    handle_subtitles_request(conn, fn -> SubtitlesHandler.get_download_url(id) end)
  end

  # Music Search
  get "/music/search" do
    params = extract_query_params(conn)
    handle_music_request(conn, fn -> MusicHandler.search(params) end)
  end

  # Music Artist Details
  get "/music/artist/:id" do
    params = extract_query_params(conn)
    handle_music_request(conn, fn -> MusicHandler.get_artist(id, params) end)
  end

  # Music Release Details
  get "/music/release/:id" do
    params = extract_query_params(conn)
    handle_music_request(conn, fn -> MusicHandler.get_release(id, params) end)
  end

  # Music Release Group Details
  get "/music/release-group/:id" do
    params = extract_query_params(conn)
    handle_music_request(conn, fn -> MusicHandler.get_release_group(id, params) end)
  end

  # Music Recording Details
  get "/music/recording/:id" do
    params = extract_query_params(conn)
    handle_music_request(conn, fn -> MusicHandler.get_recording(id, params) end)
  end

  # Music Cover Art
  get "/music/cover/:id" do
    handle_image_request(conn, fn -> MusicHandler.get_cover_art(id) end)
  end

  # OpenLibrary ISBN Lookup
  get "/openlibrary/isbn/:isbn" do
    params = extract_query_params(conn)
    handle_openlibrary_request(conn, fn -> OpenLibraryHandler.get_by_isbn(isbn, params) end)
  end

  # OpenLibrary Search
  get "/openlibrary/search" do
    params = extract_query_params(conn)
    handle_openlibrary_request(conn, fn -> OpenLibraryHandler.search(params) end)
  end

  # OpenLibrary Work Details
  get "/openlibrary/works/:id" do
    params = extract_query_params(conn)
    handle_openlibrary_request(conn, fn -> OpenLibraryHandler.get_work(id, params) end)
  end

  # OpenLibrary Author Details
  get "/openlibrary/authors/:id" do
    params = extract_query_params(conn)
    handle_openlibrary_request(conn, fn -> OpenLibraryHandler.get_author(id, params) end)
  end

  # ============================================================================
  # Pairing API - Simplified iroh-based P2P pairing
  # ============================================================================

  # Create claim code for node_addr
  post "/pairing/claim" do
    with :ok <- check_pairing_rate_limit(conn, limit: 10, window_ms: 60_000) do
      handle_pairing_request(conn, fn -> PairingHandler.create_claim(conn.body_params) end)
    else
      {:error, :rate_limited} -> send_rate_limited(conn, 60)
    end
  end

  # Get node_addr for claim code
  get "/pairing/claim/:code" do
    conn = allow_web_player(conn)

    with :ok <- check_pairing_rate_limit(conn, limit: 30, window_ms: 60_000) do
      handle_pairing_request(conn, fn -> PairingHandler.get_claim(code) end)
    else
      {:error, :rate_limited} -> send_rate_limited(conn, 60)
    end
  end

  # Preflight for the claim lookup, in case a future client adds a custom
  # header that turns the request into a non-simple one requiring a preflight.
  options "/pairing/claim/:code" do
    conn
    |> allow_web_player()
    |> put_resp_header("access-control-allow-methods", "GET, DELETE")
    |> send_resp(204, "")
  end

  # Delete claim code after successful pairing
  delete "/pairing/claim/:code" do
    conn = allow_web_player(conn)
    handle_pairing_delete(conn, fn -> PairingHandler.delete_claim(code) end)
  end

  # ============================================================================
  # Trakt.tv API Proxy
  # ============================================================================

  # Trakt Device Auth: generate device code
  post "/trakt/oauth/device/code" do
    handle_trakt_request(conn, fn -> TraktHandler.generate_device_code() end)
  end

  # Trakt Device Auth: poll for device token
  # Passes Trakt's HTTP status codes through transparently
  # (400=pending, 410=expired, 418=denied, 429=slow down)
  post "/trakt/oauth/device/token" do
    handle_trakt_device_poll(conn, fn ->
      TraktHandler.poll_device_token(conn.body_params)
    end)
  end

  # Trakt OAuth: refresh expired token
  post "/trakt/oauth/refresh" do
    handle_trakt_request(conn, fn -> TraktHandler.refresh_token(conn.body_params) end)
  end

  # Trakt OAuth: revoke token
  post "/trakt/oauth/revoke" do
    handle_trakt_request(conn, fn -> TraktHandler.revoke_token(conn.body_params) end)
  end

  # Trakt scrobble actions (start, pause, stop)
  post "/trakt/scrobble/:action" do
    with {:ok, user_token} <- get_trakt_user_token(conn) do
      handler =
        case action do
          "start" -> fn -> TraktHandler.scrobble_start(conn.body_params, user_token) end
          "pause" -> fn -> TraktHandler.scrobble_pause(conn.body_params, user_token) end
          "stop" -> fn -> TraktHandler.scrobble_stop(conn.body_params, user_token) end
          _ -> nil
        end

      if handler do
        handle_trakt_request(conn, handler)
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Invalid scrobble action: #{action}"}))
      end
    end
  end

  # Trakt sync: get items (history, ratings, watchlist, collection)
  get "/trakt/sync/:type/:media_type" do
    with {:ok, user_token} <- get_trakt_user_token(conn) do
      params = extract_query_params(conn)

      handler =
        case type do
          "history" -> fn -> TraktHandler.get_history(media_type, user_token, params) end
          "ratings" -> fn -> TraktHandler.get_ratings(media_type, user_token, params) end
          "watchlist" -> fn -> TraktHandler.get_watchlist(media_type, user_token, params) end
          "collection" -> fn -> TraktHandler.get_collection(media_type, user_token, params) end
          _ -> nil
        end

      if handler do
        handle_trakt_request(conn, handler)
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Invalid sync type: #{type}"}))
      end
    end
  end

  # Trakt sync: add items
  post "/trakt/sync/:type" do
    with {:ok, user_token} <- get_trakt_user_token(conn) do
      handler =
        case type do
          "history" -> fn -> TraktHandler.add_to_history(conn.body_params, user_token) end
          "ratings" -> fn -> TraktHandler.add_ratings(conn.body_params, user_token) end
          "watchlist" -> fn -> TraktHandler.add_to_watchlist(conn.body_params, user_token) end
          "collection" -> fn -> TraktHandler.add_to_collection(conn.body_params, user_token) end
          _ -> nil
        end

      if handler do
        handle_trakt_request(conn, handler)
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Invalid sync type: #{type}"}))
      end
    end
  end

  # Trakt sync: remove items
  post "/trakt/sync/:type/remove" do
    with {:ok, user_token} <- get_trakt_user_token(conn) do
      handler =
        case type do
          "history" ->
            fn -> TraktHandler.remove_from_history(conn.body_params, user_token) end

          "ratings" ->
            fn -> TraktHandler.remove_ratings(conn.body_params, user_token) end

          "watchlist" ->
            fn -> TraktHandler.remove_from_watchlist(conn.body_params, user_token) end

          "collection" ->
            fn -> TraktHandler.remove_from_collection(conn.body_params, user_token) end

          _ ->
            nil
        end

      if handler do
        handle_trakt_request(conn, handler)
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Invalid sync type: #{type}"}))
      end
    end
  end

  # 404 catch-all
  match _ do
    send_resp(conn, 404, "Not found")
  end

  # Private helpers

  # The web player is served from a different origin than this service, so the
  # claim lookup needs CORS. Scoped to the pairing routes rather than applied
  # as a global plug: the metadata proxy endpoints are called server-to-server
  # by Mydia instances and have no reason to be browser-reachable.
  defp allow_web_player(conn) do
    put_resp_header(conn, "access-control-allow-origin", "*")
  end

  defp handle_tmdb_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total", service: "tmdb", status: "ok")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:http_error, status, body}} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "tmdb",
          status: "error"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, reason} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "tmdb",
          status: "error"
        )

        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp handle_tvdb_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total", service: "tvdb", status: "ok")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:http_error, status, body}} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "tvdb",
          status: "error"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, {:authentication_failed, reason}} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "tvdb",
          status: "error"
        )

        error_response = %{
          error: "Authentication failed",
          message: "Failed to authenticate with TVDB: #{inspect(reason)}"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(error_response))

      {:error, reason} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "tvdb",
          status: "error"
        )

        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp extract_query_params(conn) do
    conn.query_params
    |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp extract_body_params(conn) do
    conn.body_params
    |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    |> Map.new()
  end

  defp handle_crash_report(conn) do
    # Check rate limit first (by IP address)
    client_ip = get_client_ip(conn)

    case MetadataRelay.RateLimiter.check_rate_limit(client_ip) do
      {:error, :rate_limited} ->
        MetadataRelay.Metrics.inc("metadata_relay_rate_limited_total")

        error_response = %{
          error: "Too many requests",
          message: "Rate limit exceeded. Please try again later."
        }

        conn
        |> put_resp_header("retry-after", "60")
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(error_response))

      {:ok, _remaining} ->
        # Rate limit passed - process the crash report
        process_crash_report(conn)
    end
  end

  defp get_client_ip(conn) do
    # Get the client IP from the connection
    # Check X-Forwarded-For header first (for proxied requests)
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        # Fall back to remote_ip
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  defp process_crash_report(conn) do
    with {:ok, body} <- validate_crash_report(conn.body_params),
         {:ok, _occurrence} <- store_crash_report(body) do
      MetadataRelay.Metrics.inc("metadata_relay_crash_reports_total")

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(%{status: "created", message: "Crash report received"}))
    else
      {:error, :invalid_json} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "Invalid JSON", message: "Request body must be valid JSON"})
        )

      {:error, {:validation, errors}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Validation failed", errors: errors}))

      {:error, reason} ->
        error_response = %{
          error: "Internal server error",
          message: "Failed to store crash report: #{inspect(reason)}"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp validate_crash_report(params) when is_map(params) do
    required_fields = ["error_type", "error_message", "stacktrace"]

    errors =
      required_fields
      |> Enum.reject(&Map.has_key?(params, &1))
      |> Enum.map(&"Missing required field: #{&1}")

    # Validate stacktrace is a list
    stacktrace_errors =
      case Map.get(params, "stacktrace") do
        st when is_list(st) -> []
        _ -> ["stacktrace must be a list"]
      end

    all_errors = errors ++ stacktrace_errors

    if all_errors == [] do
      {:ok, params}
    else
      {:error, {:validation, all_errors}}
    end
  end

  defp validate_crash_report(_), do: {:error, :invalid_json}

  defp store_crash_report(body) do
    # Use the reported error type as the ErrorTracker kind so different error
    # types are not collapsed together. The message is kept as the reason.
    error_type = Map.get(body, "error_type", "RuntimeError")
    error_message = Map.get(body, "error_message", "Unknown error")

    # Reconstruct stacktrace from the crash report
    stacktrace =
      body
      |> Map.get("stacktrace", [])
      |> Enum.map(&parse_stacktrace_entry/1)
      |> Enum.filter(& &1)

    # Clients typically send an empty stacktrace and describe the crash site in
    # `metadata`. Without any source info, ErrorTracker derives the same
    # fingerprint for every report and collapses them into a single error.
    # Synthesize a frame from `metadata` so each crash site stays distinct.
    stacktrace =
      case stacktrace do
        [] -> List.wrap(metadata_stack_frame(Map.get(body, "metadata")))
        frames -> frames
      end

    # Create context from additional metadata
    context = %{
      version: Map.get(body, "version"),
      environment: Map.get(body, "environment"),
      occurred_at: Map.get(body, "occurred_at"),
      metadata: Map.get(body, "metadata", %{})
    }

    # Report to ErrorTracker as a {kind, reason} tuple so the reported
    # error_type is preserved as the error kind.
    case ErrorTracker.report({error_type, error_message}, stacktrace, context) do
      :noop ->
        {:error, :error_tracker_disabled}

      occurrence ->
        {:ok, occurrence}
    end
  end

  # Build a synthetic stacktrace frame from the crash report `metadata` map.
  # Returns nil when there is no usable source information.
  defp metadata_stack_frame(metadata) when is_map(metadata) do
    file = Map.get(metadata, "file")
    line = Map.get(metadata, "line")

    if file || line do
      crash_frame(Map.get(metadata, "module"), Map.get(metadata, "function"), file, line)
    end
  end

  defp metadata_stack_frame(_), do: nil

  defp parse_stacktrace_entry(%{"file" => file, "line" => line} = entry) do
    crash_frame(Map.get(entry, "module"), Map.get(entry, "function"), file, line)
  end

  defp parse_stacktrace_entry(_), do: nil

  # Build a stacktrace frame in the {module, function, arity, location} shape that
  # ErrorTracker.Stacktrace.new/1 expects. The module position is always `nil`
  # (a safe atom) because ErrorTracker passes it to Application.get_application/1,
  # which requires an atom; we never call String.to_atom/1 on untrusted module
  # names (atom-table exhaustion risk). The readable module name is folded into
  # the function descriptor instead, and the file:line drives the fingerprint.
  defp crash_frame(module, function, file, line) do
    {name, arity} = parse_function(function)
    {nil, qualify(module, name), arity, build_location(file, line)}
  end

  defp qualify(nil, name), do: name

  defp qualify(module, name) do
    case to_string(module) |> String.replace_prefix("Elixir.", "") do
      "" -> name
      mod -> "#{mod}.#{name}"
    end
  end

  # Split a "name/arity" function descriptor (e.g. "import_download/2") into its
  # name and integer arity. Falls back to arity 0 when the format is unexpected.
  defp parse_function(function) when is_binary(function) do
    case String.split(function, "/", parts: 2) do
      [name, arity] ->
        case Integer.parse(arity) do
          {n, ""} -> {name, n}
          _ -> {function, 0}
        end

      [name] ->
        {name, 0}
    end
  end

  defp parse_function(nil), do: {"unknown", 0}
  defp parse_function(function), do: {to_string(function), 0}

  defp build_location(nil, nil), do: []
  defp build_location(nil, line), do: [line: line]
  defp build_location(file, nil), do: [file: String.to_charlist(file)]
  defp build_location(file, line), do: [file: String.to_charlist(file), line: line]

  defp handle_feedback(conn) do
    client_ip = get_client_ip(conn)
    instance_id = feedback_rate_limit_instance_id(conn.body_params)

    with {:ok, _remaining} <-
           MetadataRelay.RateLimiter.check_rate_limit("feedback:ip:#{client_ip}",
             limit: 5,
             window_ms: 3_600_000
           ),
         {:ok, _remaining} <-
           MetadataRelay.RateLimiter.check_rate_limit("feedback:instance:#{instance_id}",
             limit: 5,
             window_ms: 3_600_000
           ) do
      process_feedback(conn, client_ip)
    else
      {:error, :rate_limited} ->
        MetadataRelay.Metrics.inc("metadata_relay_rate_limited_total")

        conn
        |> put_resp_header("retry-after", "3600")
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Jason.encode!(%{
            error: "Too many requests",
            message: "Rate limit exceeded. Please try again later."
          })
        )
    end
  end

  defp process_feedback(conn, client_ip) do
    with {:ok, attrs} <- validate_feedback(conn.body_params),
         attrs = Map.put(attrs, :source_ip, client_ip),
         {:ok, submission} <- MetadataRelay.Feedback.create_submission(attrs) do
      schedule_feedback_notification(submission)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(%{status: "created", id: submission.id}))
    else
      {:error, :invalid_json} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "Invalid JSON", message: "Request body must be valid JSON"})
        )

      {:error, :message_too_long} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Message too long", limit_bytes: 4096}))

      {:error, {:validation, errors}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Validation failed", errors: errors}))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            error: "Validation failed",
            errors: changeset_error_messages(changeset)
          })
        )

      {:error, reason} ->
        Logger.error("Failed to store feedback", reason: inspect(reason))

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: "Internal server error"}))
    end
  end

  defp validate_feedback(params) when is_map(params) do
    type = get_feedback_param(params, "type")
    message = get_feedback_param(params, "message")
    contact = get_feedback_param(params, "contact")
    instance_id = get_feedback_param(params, "instance_id")
    mydia_version = get_feedback_param(params, "mydia_version")

    errors =
      []
      |> require_feedback_field("type", type)
      |> require_feedback_field("message", message)
      |> validate_feedback_type(type)
      |> validate_optional_feedback_field("contact", contact)
      |> validate_optional_feedback_field("instance_id", instance_id)
      |> validate_optional_feedback_field("mydia_version", mydia_version)

    cond do
      errors != [] ->
        {:error, {:validation, Enum.reverse(errors)}}

      byte_size(message) > 4096 ->
        {:error, :message_too_long}

      true ->
        {:ok,
         %{
           type: type,
           message: message,
           contact: normalize_optional_feedback_field(contact),
           instance_id: normalize_optional_feedback_field(instance_id),
           mydia_version: normalize_optional_feedback_field(mydia_version)
         }}
    end
  end

  defp validate_feedback(_), do: {:error, :invalid_json}

  defp schedule_feedback_notification(submission) do
    case Task.Supervisor.start_child(MetadataRelay.TaskSupervisor, fn ->
           notify_feedback_submission(submission)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule feedback notification email", reason: inspect(reason))
        :ok
    end
  end

  defp notify_feedback_submission(submission) do
    case MetadataRelay.Feedback.Notifier.deliver_new_submission(submission) do
      :ok ->
        :ok

      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to send feedback notification email", reason: inspect(reason))
        :ok
    end
  rescue
    exception ->
      Logger.error("Failed to send feedback notification email",
        reason: Exception.message(exception)
      )

      :ok
  end

  defp feedback_rate_limit_instance_id(params) when is_map(params) do
    case get_feedback_param(params, "instance_id") do
      value when is_binary(value) and value != "" -> value
      _ -> "anonymous"
    end
  end

  defp feedback_rate_limit_instance_id(_), do: "anonymous"

  defp get_feedback_param(params, key) do
    Map.get(params, key) || Map.get(params, Map.fetch!(@feedback_param_atoms, key))
  end

  defp require_feedback_field(errors, field, value) do
    if is_binary(value) && String.trim(value) != "" do
      errors
    else
      ["Missing required field: #{field}" | errors]
    end
  end

  defp validate_feedback_type(errors, type) when type in ["bug", "idea", "question"], do: errors

  defp validate_feedback_type(errors, type) when is_binary(type) and type != "" do
    ["Invalid type: #{type}" | errors]
  end

  defp validate_feedback_type(errors, _type), do: errors

  defp validate_optional_feedback_field(errors, _field, nil), do: errors
  defp validate_optional_feedback_field(errors, _field, value) when is_binary(value), do: errors

  defp validate_optional_feedback_field(errors, field, _value) do
    ["Invalid field: #{field}" | errors]
  end

  defp normalize_optional_feedback_field(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_feedback_field(_value), do: nil

  defp changeset_error_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(List.wrap(messages), fn message -> "#{field} #{message}" end)
    end)
  end

  defp handle_subtitles_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "opensubtitles",
          status: "ok"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, :not_configured} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "opensubtitles",
          status: "error"
        )

        error_response = %{
          error: "Service not configured",
          message:
            "OpenSubtitles integration is not configured. Please set OPENSUBTITLES_API_KEY, OPENSUBTITLES_USERNAME, and OPENSUBTITLES_PASSWORD environment variables."
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(error_response))

      {:error, {:rate_limited, retry_after}} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "opensubtitles",
          status: "error"
        )

        error_response = %{
          error: "Too many requests",
          message: "Rate limit exceeded. Please try again later."
        }

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(error_response))

      {:error, {:http_error, status, body}} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "opensubtitles",
          status: "error"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, {:authentication_failed, reason}} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "opensubtitles",
          status: "error"
        )

        error_response = %{
          error: "Authentication failed",
          message: "Failed to authenticate with OpenSubtitles: #{inspect(reason)}"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(error_response))

      {:error, reason} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "opensubtitles",
          status: "error"
        )

        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp handle_music_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "musicbrainz",
          status: "ok"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:http_error, status, body}} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "musicbrainz",
          status: "error"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, reason} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "musicbrainz",
          status: "error"
        )

        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp handle_openlibrary_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "openlibrary",
          status: "ok"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:http_error, status, body}} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "openlibrary",
          status: "error"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, reason} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "openlibrary",
          status: "error"
        )

        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp handle_image_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("image/jpeg")
        |> send_resp(200, body)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, {:http_error, status}} ->
        send_resp(conn, status, "Upstream error")

      {:error, reason} ->
        send_resp(conn, 500, inspect(reason))
    end
  end

  defp check_pairing_rate_limit(conn, opts) do
    client_ip = get_client_ip(conn)
    key = "pairing:#{client_ip}"

    case MetadataRelay.RateLimiter.check_rate_limit(key, opts) do
      {:ok, _remaining} -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  defp send_rate_limited(conn, retry_after_seconds) do
    MetadataRelay.Metrics.inc("metadata_relay_rate_limited_total")

    error_response = %{
      error: "rate_limited",
      message: "Too many requests. Please try again later.",
      retry_after: retry_after_seconds
    }

    conn
    |> put_resp_header("retry-after", to_string(retry_after_seconds))
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(error_response))
  end

  # Trakt device poll handler — passes Trakt's HTTP status codes through transparently
  # so the client can distinguish pending (400), expired (410), denied (418), slow down (429)
  defp handle_trakt_device_poll(conn, handler_fn) do
    with_trakt_configured(conn, fn ->
      do_handle_trakt_device_poll(conn, handler_fn)
    end)
  end

  defp do_handle_trakt_device_poll(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "trakt",
          status: "ok"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:http_error, status, body}} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "trakt",
          status: "poll"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, reason} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "trakt",
          status: "error"
        )

        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  # Trakt request handler
  defp handle_trakt_request(conn, handler_fn) do
    with_trakt_configured(conn, fn ->
      do_handle_trakt_request(conn, handler_fn)
    end)
  end

  # Trakt credentials are optional: a relay without them still serves TMDB and
  # TVDB. Reply with a machine-readable 503 so clients can tell "this relay has
  # no Trakt" apart from a transient outage, instead of raising into a 500.
  defp with_trakt_configured(conn, fun) do
    if TraktClient.configured?() do
      fun.()
    else
      MetadataRelay.Metrics.inc("metadata_relay_requests_total",
        service: "trakt",
        status: "not_configured"
      )

      body = %{
        error: "trakt_not_configured",
        message:
          "This metadata relay has no Trakt credentials configured. " <>
            "Set TRAKT_CLIENT_ID and TRAKT_CLIENT_SECRET on the relay to enable Trakt."
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(body))
    end
  end

  defp do_handle_trakt_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "trakt",
          status: "ok"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, {:http_error, status, body}} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "trakt",
          status: "error"
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))

      {:error, reason} ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total",
          service: "trakt",
          status: "error"
        )

        error_response = %{
          error: "Internal server error",
          message: inspect(reason)
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  defp get_trakt_user_token(conn) do
    case get_req_header(conn, "x-trakt-user-token") do
      [token | _] when byte_size(token) > 0 ->
        {:ok, token}

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{error: "Missing X-Trakt-User-Token header"})
        )
    end
  end

  # Pairing request handler
  defp handle_pairing_request(conn, handler_fn) do
    case handler_fn.() do
      {:ok, body} ->
        MetadataRelay.Metrics.inc("metadata_relay_pairing_requests_total")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, :not_found} ->
        error_response = %{error: "Not found", message: "Claim code not found or expired"}

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(error_response))

      {:error, {:validation, message}} ->
        error_response = %{error: "Validation error", message: message}

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(error_response))

      {:error, reason} ->
        error_response = %{error: "Internal server error", message: inspect(reason)}

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end

  # Pairing delete handler (returns 204 No Content)
  defp handle_pairing_delete(conn, handler_fn) do
    case handler_fn.() do
      {:ok, :no_content} ->
        send_resp(conn, 204, "")

      {:error, reason} ->
        error_response = %{error: "Internal server error", message: inspect(reason)}

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error_response))
    end
  end
end
