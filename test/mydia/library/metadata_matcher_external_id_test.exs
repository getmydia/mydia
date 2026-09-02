defmodule Mydia.Library.MetadataMatcherExternalIdTest do
  @moduledoc """
  Covers the direct-lookup-by-folder-id path when the captured id is not
  numeric.

  `Mydia.Library.PathParser` accepts any non-`]` characters after `tmdb-` or
  `tvdb-` (e.g. a folder named `[tmdb-abc]`), so `parsed.external_id` is not
  guaranteed to be a decimal string. The direct lookup branches used to feed
  it straight into `String.to_integer/1`, which raises instead of falling
  back to title matching -- and nothing between here and
  `Mydia.Library.BatchMatcher.safe_match_file/3` rescues that, so a single
  malformed folder name would abort the whole match instead of degrading to
  a title search.
  """

  use Mydia.DataCase, async: false

  alias Mydia.Library.MetadataMatcher
  alias Mydia.Metadata.Cache

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 2_000}
    }

    Cache.clear()
    on_exit(fn -> Cache.clear() end)

    {:ok, bypass: bypass, config: config}
  end

  defp stub(bypass, path, body) do
    Bypass.stub(bypass, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  test "a non-numeric TMDB external id on a movie falls back to title search instead of raising",
       %{bypass: bypass, config: config} do
    parsed = %{
      type: :movie,
      title: "Harbor Static",
      year: 2020,
      quality: %{},
      confidence: 1.0,
      external_id: "abc",
      external_provider: :tmdb
    }

    stub(bypass, "/tmdb/movies/search", %{
      "results" => [
        %{"id" => 555_001, "title" => "Harbor Static", "release_date" => "2020-01-01"}
      ]
    })

    assert {:ok, match} = MetadataMatcher.match_movie(parsed, config)
    assert match.match_type != :direct_id_lookup
    assert match.provider_id == "555001"
  end

  test "a non-numeric TMDB external id on a TV show falls back to title search instead of raising",
       %{bypass: bypass, config: config} do
    parsed = %{
      type: :tv_show,
      title: "Harbor Signal",
      year: 2020,
      season: 1,
      episodes: [1],
      confidence: 1.0,
      external_id: "abc",
      external_provider: :tmdb
    }

    stub(bypass, "/tmdb/tv/search", %{
      "results" => [
        %{"id" => 555_002, "name" => "Harbor Signal", "first_air_date" => "2020-01-01"}
      ]
    })

    assert {:ok, match} = MetadataMatcher.match_tv_show(parsed, config, provider: :tmdb)
    assert match.match_type != :direct_id_lookup
    assert match.provider_id == "555002"
  end

  test "a non-numeric TVDB external id on a TV show falls back to title search instead of raising",
       %{bypass: bypass, config: config} do
    parsed = %{
      type: :tv_show,
      title: "Harbor Relay",
      year: 2020,
      season: 1,
      episodes: [1],
      confidence: 1.0,
      external_id: "abc",
      external_provider: :tvdb
    }

    stub(bypass, "/tvdb/search", %{
      "data" => [
        %{"tvdb_id" => 555_003, "name" => "Harbor Relay", "year" => "2020"}
      ]
    })

    assert {:ok, match} = MetadataMatcher.match_tv_show(parsed, config)
    assert match.match_type != :direct_id_lookup
    assert match.provider_id == "555003"
  end

  test "a partially-numeric TMDB external id (a valid prefix followed by junk) also falls back",
       %{bypass: bypass, config: config} do
    parsed = %{
      type: :movie,
      title: "Harbor Static",
      year: 2020,
      quality: %{},
      confidence: 1.0,
      external_id: "123abc",
      external_provider: :tmdb
    }

    stub(bypass, "/tmdb/movies/search", %{
      "results" => [
        %{"id" => 555_004, "title" => "Harbor Static", "release_date" => "2020-01-01"}
      ]
    })

    assert {:ok, match} = MetadataMatcher.match_movie(parsed, config)
    assert match.match_type != :direct_id_lookup
    assert match.provider_id == "555004"
  end
end
