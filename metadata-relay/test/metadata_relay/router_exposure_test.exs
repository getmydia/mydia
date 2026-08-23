defmodule MetadataRelay.RouterExposureTest do
  @moduledoc """
  MetadataRelay.Router is a Plug.Router, so routes cannot be enumerated at
  runtime. This test parses the router source instead, and asserts the set of
  declared routes matches an explicit snapshot.

  Every relay endpoint is unauthenticated by design. This test exists to make
  additions visible, not to assert they are safe.
  """
  use ExUnit.Case, async: true

  @router_path Path.join(__DIR__, "../../lib/metadata_relay/router.ex")

  @known_routes [
    {"get", "/health"},
    {"get", "/stats"},
    {"get", "/metrics"},
    {"get", "/configuration"},
    {"get", "/tmdb/movies/search"},
    {"get", "/tmdb/tv/search"},
    {"get", "/tmdb/movies/trending"},
    {"get", "/tmdb/movies/popular"},
    {"get", "/tmdb/movies/upcoming"},
    {"get", "/tmdb/movies/now_playing"},
    {"get", "/tmdb/tv/trending"},
    {"get", "/tmdb/tv/popular"},
    {"get", "/tmdb/tv/on_the_air"},
    {"get", "/tmdb/tv/airing_today"},
    {"get", "/tmdb/movies/discover"},
    {"get", "/tmdb/tv/discover"},
    {"get", "/tmdb/genre/movie"},
    {"get", "/tmdb/genre/tv"},
    {"get", "/tmdb/list/:id"},
    {"get", "/tmdb/collections/:id"},
    {"get", "/tmdb/movies/:id"},
    {"get", "/tmdb/tv/shows/:id"},
    {"get", "/tmdb/movies/:id/images"},
    {"get", "/tmdb/tv/shows/:id/images"},
    {"get", "/tmdb/tv/shows/:id/:season"},
    {"get", "/tvdb/search"},
    {"get", "/tvdb/series/:id"},
    {"get", "/tvdb/series/:id/extended"},
    {"get", "/tvdb/series/:id/episodes"},
    {"get", "/tvdb/seasons/:id"},
    {"get", "/tvdb/seasons/:id/extended"},
    {"get", "/tvdb/episodes/:id"},
    {"get", "/tvdb/episodes/:id/extended"},
    {"get", "/tvdb/artwork/:id"},
    {"post", "/crashes/report"},
    {"post", "/feedback"},
    {"post", "/api/v1/subtitles/search"},
    {"get", "/api/v1/subtitles/download-url/:id"},
    {"get", "/api/v1/subtitles/download/:id"},
    {"get", "/music/search"},
    {"get", "/music/artist/:id"},
    {"get", "/music/release/:id"},
    {"get", "/music/release-group/:id"},
    {"get", "/music/recording/:id"},
    {"get", "/music/cover/:id"},
    {"get", "/openlibrary/isbn/:isbn"},
    {"get", "/openlibrary/search"},
    {"get", "/openlibrary/works/:id"},
    {"get", "/openlibrary/authors/:id"},
    {"post", "/pairing/claim"},
    {"get", "/pairing/claim/:code"},
    {"options", "/pairing/claim/:code"},
    {"delete", "/pairing/claim/:code"},
    {"post", "/pairing/v2/claim"},
    {"get", "/pairing/v2/claim/:lookup_key"},
    {"options", "/pairing/v2/claim/:lookup_key"},
    {"delete", "/pairing/v2/claim/:lookup_key"},
    {"match", "_"}
  ]

  test "declared relay routes match the snapshot" do
    declared = parse_routes()

    assert Enum.sort(declared) == Enum.sort(@known_routes),
           """
           Relay route set changed.
           Added:   #{inspect(declared -- @known_routes)}
           Removed: #{inspect(@known_routes -- declared)}
           """
  end

  defp parse_routes do
    @router_path
    |> File.read!()
    |> then(&Regex.scan(~r/^\s*(get|post|put|patch|delete|options|match)\s+"?([^"\s]+)"?/m, &1))
    |> Enum.map(fn [_full, verb, path] -> {verb, path} end)
    |> Enum.uniq()
  end
end
