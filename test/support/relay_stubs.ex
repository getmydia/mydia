defmodule Mydia.RelayStubs do
  @moduledoc """
  Bypass stubs for relay detail routes that behave like TMDB: a rating
  resource (`release_dates` for movies, `content_ratings` for TV) is only in
  the body when the request's `append_to_response` names it.

  Stubs that always include it hid #1000, where the add and request paths
  never asked for a rating and production saw none.
  """

  def relay_config(bypass) do
    %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 2_000, connect_timeout: 1_000}
    }
  end

  def stub_tmdb_movie(bypass, id, opts \\ []) do
    stub(bypass, "/tmdb/movies/#{id}", opts, fn append ->
      base = %{
        "id" => id,
        "title" => Keyword.get(opts, :title, "Untitled Fixture"),
        "release_date" => "2021-03-04",
        "genres" => genres(opts),
        "origin_country" => Keyword.get(opts, :origin_country, []),
        "original_language" => Keyword.get(opts, :original_language, "en"),
        "credits" => %{"cast" => [], "crew" => []}
      }

      if "release_dates" in append do
        Map.put(base, "release_dates", %{"results" => movie_rating(opts)})
      else
        base
      end
    end)
  end

  def stub_tmdb_tv(bypass, id, opts \\ []) do
    stub(bypass, "/tmdb/tv/shows/#{id}", opts, fn append ->
      base = %{
        "id" => id,
        "name" => Keyword.get(opts, :title, "Untitled Fixture"),
        "first_air_date" => "2021-03-04",
        "genres" => genres(opts),
        "origin_country" => Keyword.get(opts, :origin_country, []),
        "original_language" => Keyword.get(opts, :original_language, "en"),
        "credits" => %{"cast" => [], "crew" => []},
        "external_ids" => %{}
      }

      if "content_ratings" in append do
        Map.put(base, "content_ratings", %{"results" => tv_rating(opts)})
      else
        base
      end
    end)
  end

  def stub_tvdb_series(bypass, id, opts \\ []) do
    stub(bypass, "/tvdb/series/#{id}/extended", opts, fn _append ->
      remote_ids =
        case Keyword.get(opts, :remote_tmdb_id) do
          nil -> []
          tmdb_id -> [%{"sourceName" => "TheMovieDB.com", "id" => to_string(tmdb_id)}]
        end

      ratings =
        case Keyword.get(opts, :certification) do
          nil -> []
          cert -> [%{"name" => cert, "country" => "usa"}]
        end

      %{
        "data" => %{
          "id" => id,
          "name" => Keyword.get(opts, :title, "Untitled Fixture"),
          "firstAired" => "2021-03-04",
          "genres" => Enum.map(Keyword.get(opts, :genres, []), &%{"name" => &1}),
          "contentRatings" => ratings,
          "remoteIds" => remote_ids,
          "trailers" => [],
          "seasons" => []
        }
      }
    end)
  end

  defp stub(bypass, path, opts, body_fun) do
    test_pid = Keyword.get(opts, :test_pid)

    Bypass.stub(bypass, "GET", path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      append = String.split(conn.query_params["append_to_response"] || "", ",", trim: true)
      if test_pid, do: send(test_pid, {:relay_hit, path, append})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body_fun.(append)))
    end)
  end

  defp genres(opts), do: opts |> Keyword.get(:genres, []) |> Enum.map(&%{"name" => &1})

  defp movie_rating(opts) do
    case Keyword.get(opts, :certification) do
      nil ->
        []

      cert ->
        [
          %{
            "iso_3166_1" => Keyword.get(opts, :country, "US"),
            "release_dates" => [%{"certification" => cert}]
          }
        ]
    end
  end

  defp tv_rating(opts) do
    case Keyword.get(opts, :certification) do
      nil -> []
      cert -> [%{"iso_3166_1" => Keyword.get(opts, :country, "US"), "rating" => cert}]
    end
  end
end
