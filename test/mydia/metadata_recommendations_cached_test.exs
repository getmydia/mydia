defmodule Mydia.MetadataRecommendationsCachedTest do
  @moduledoc """
  Covers the ETS memoisation around `Relay.fetch_recommendations/3`, in
  particular that the cache key varies by the two dimensions that would
  otherwise serve one library's results to another: language and media type.
  """

  use ExUnit.Case, async: false

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Provider.Error

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 2_000}
    }

    tmdb_id = to_string(900_000_000 + System.unique_integer([:positive]))

    on_exit(fn ->
      for media_type <- [:movie, :tv_show], language <- ["en-US", "fr-FR"] do
        Cache.delete("recommendations:metadata_relay:#{tmdb_id}:#{media_type}:#{language}")
      end
    end)

    {:ok, bypass: bypass, config: config, tmdb_id: tmdb_id}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp recommendations_body(tmdb_id, title) do
    %{
      "id" => String.to_integer(tmdb_id),
      "title" => "Source",
      "recommendations" => %{
        "page" => 1,
        "results" => [
          %{
            "id" => 101,
            "title" => title,
            "release_date" => "2022-10-21",
            "poster_path" => "/p.jpg"
          }
        ],
        "total_pages" => 1,
        "total_results" => 1
      }
    }
  end

  test "serves a repeat call from cache without a second request", %{
    bypass: bypass,
    config: config,
    tmdb_id: tmdb_id
  } do
    Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      json(conn, 200, recommendations_body(tmdb_id, "Cached Title"))
    end)

    assert {:ok, [first]} =
             Metadata.fetch_recommendations_cached(config, tmdb_id, media_type: :movie)

    assert first.title == "Cached Title"

    # Bypass.expect_once would fail on a second request.
    assert {:ok, [^first]} =
             Metadata.fetch_recommendations_cached(config, tmdb_id, media_type: :movie)
  end

  test "keys the cache by language", %{bypass: bypass, config: config, tmdb_id: tmdb_id} do
    Bypass.expect(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      title = if conn.query_params["language"] == "fr-FR", do: "Titre", else: "Title"
      json(conn, 200, recommendations_body(tmdb_id, title))
    end)

    assert {:ok, [english]} =
             Metadata.fetch_recommendations_cached(config, tmdb_id, media_type: :movie)

    assert {:ok, [french]} =
             Metadata.fetch_recommendations_cached(config, tmdb_id,
               media_type: :movie,
               language: "fr-FR"
             )

    assert english.title == "Title"
    assert french.title == "Titre"
  end

  test "keys the cache by media type", %{bypass: bypass, config: config, tmdb_id: tmdb_id} do
    Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      json(conn, 200, recommendations_body(tmdb_id, "A Movie"))
    end)

    Bypass.expect_once(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}", fn conn ->
      json(conn, 200, %{
        "id" => String.to_integer(tmdb_id),
        "name" => "Source Show",
        "recommendations" => %{
          "page" => 1,
          "results" => [%{"id" => 202, "name" => "A Show", "first_air_date" => "2008-01-20"}],
          "total_pages" => 1,
          "total_results" => 1
        }
      })
    end)

    assert {:ok, [movie]} =
             Metadata.fetch_recommendations_cached(config, tmdb_id, media_type: :movie)

    assert {:ok, [show]} =
             Metadata.fetch_recommendations_cached(config, tmdb_id, media_type: :tv_show)

    assert movie.title == "A Movie"
    assert show.media_type == :tv_show
  end

  test "rejects a non-relay provider config", %{tmdb_id: tmdb_id} do
    assert {:error, %Error{type: :invalid_config}} =
             Metadata.fetch_recommendations_cached(%{type: :not_the_relay}, tmdb_id,
               media_type: :movie
             )
  end
end
