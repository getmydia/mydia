defmodule Mydia.Metadata.Provider.RelayRecommendationsTest do
  @moduledoc """
  Offline coverage for TMDB recommendations, which ride along on the details
  endpoint via `append_to_response` rather than a dedicated relay route.

  Deliberately NOT tagged `:external` — `test/test_helper.exs` excludes that tag,
  and this parsing has to run in CI. The relay is stubbed with Bypass.
  """

  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.{Error, Relay}

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{
        language: "en-US",
        include_adult: false,
        timeout: 2_000,
        connect_timeout: 1_000
      }
    }

    # Offset well past any real provider id so the process-global
    # Mydia.Metadata.ProviderIDRegistry entries these tests create can never
    # collide with another test file's ids.
    tmdb_id = to_string(900_000_000 + System.unique_integer([:positive]))

    {:ok, bypass: bypass, config: config, tmdb_id: tmdb_id}
  end

  # Req only decodes a body when the response declares a JSON content type.
  # Without this the assertions below would run against a raw string.
  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp movie_rec(id, title) do
    %{
      "id" => id,
      "title" => title,
      "release_date" => "2022-10-21",
      "poster_path" => "/poster#{id}.jpg",
      "vote_average" => 7.6,
      "overview" => "Overview for #{title}"
    }
  end

  defp tv_rec(id, name) do
    %{
      "id" => id,
      "name" => name,
      "first_air_date" => "2008-01-20",
      "poster_path" => "/poster#{id}.jpg",
      "vote_average" => 8.9,
      "overview" => "Overview for #{name}"
    }
  end

  describe "fetch_recommendations/3 for movies" do
    test "sends append_to_response and parses the sub-object", %{
      bypass: bypass,
      config: config,
      tmdb_id: tmdb_id
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:query_params, conn.query_params})

        json(conn, 200, %{
          "id" => String.to_integer(tmdb_id),
          "title" => "Aftersun",
          "recommendations" => %{
            "page" => 1,
            "results" => [
              movie_rec(101, "The Eternal Daughter"),
              movie_rec(102, "Janet Planet")
            ],
            "total_pages" => 1,
            "total_results" => 2
          }
        })
      end)

      assert {:ok, [first, second]} =
               Relay.fetch_recommendations(config, tmdb_id, media_type: :movie)

      assert_receive {:query_params, params}
      assert params["append_to_response"] == "recommendations"
      assert params["language"] == "en-US"

      assert first.provider_id == "101"
      assert first.title == "The Eternal Daughter"
      assert first.media_type == :movie
      assert second.provider_id == "102"
    end

    test "returns an empty list when the sub-object has no results", %{
      bypass: bypass,
      config: config,
      tmdb_id: tmdb_id
    } do
      Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
        json(conn, 200, %{
          "id" => String.to_integer(tmdb_id),
          "title" => "Obscure Film",
          "recommendations" => %{
            "page" => 1,
            "results" => [],
            "total_pages" => 0,
            "total_results" => 0
          }
        })
      end)

      assert {:ok, []} = Relay.fetch_recommendations(config, tmdb_id, media_type: :movie)
    end

    test "returns an empty list when the response has no recommendations key", %{
      bypass: bypass,
      config: config,
      tmdb_id: tmdb_id
    } do
      Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
        json(conn, 200, %{"id" => String.to_integer(tmdb_id), "title" => "No Append"})
      end)

      assert {:ok, []} = Relay.fetch_recommendations(config, tmdb_id, media_type: :movie)
    end

    test "returns a not_found error on 404", %{
      bypass: bypass,
      config: config,
      tmdb_id: tmdb_id
    } do
      Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
        json(conn, 404, %{"status_message" => "The resource you requested could not be found."})
      end)

      assert {:error, %Error{type: :not_found}} =
               Relay.fetch_recommendations(config, tmdb_id, media_type: :movie)
    end

    test "honours an explicit language override", %{
      bypass: bypass,
      config: config,
      tmdb_id: tmdb_id
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:query_params, conn.query_params})
        json(conn, 200, %{"id" => String.to_integer(tmdb_id), "title" => "Aftersun"})
      end)

      assert {:ok, []} =
               Relay.fetch_recommendations(config, tmdb_id,
                 media_type: :movie,
                 language: "fr-FR"
               )

      assert_receive {:query_params, params}
      assert params["language"] == "fr-FR"
    end
  end

  describe "fetch_recommendations/3 for TV shows" do
    test "uses the TV details endpoint and tags results as tv_show", %{
      bypass: bypass,
      config: config,
      tmdb_id: tmdb_id
    } do
      Bypass.expect_once(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}", fn conn ->
        json(conn, 200, %{
          "id" => String.to_integer(tmdb_id),
          "name" => "Breaking Bad",
          "recommendations" => %{
            "page" => 1,
            "results" => [tv_rec(201, "Better Call Saul")],
            "total_pages" => 1,
            "total_results" => 1
          }
        })
      end)

      assert {:ok, [first]} =
               Relay.fetch_recommendations(config, tmdb_id, media_type: :tv_show)

      assert first.provider_id == "201"
      assert first.media_type == :tv_show
    end
  end
end
