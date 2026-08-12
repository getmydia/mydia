defmodule Mydia.Subtitles.Provider.SubDLTest do
  use ExUnit.Case, async: true

  alias Mydia.Subtitles.Provider.SubDL

  setup do
    bypass = Bypass.open()

    config = %{
      name: "SubDL",
      type: :subdl,
      api_key: "test-key",
      base_url: "http://localhost:#{bypass.port}",
      download_host: "http://localhost:#{bypass.port}"
    }

    {:ok, bypass: bypass, config: config}
  end

  defp search_response do
    Jason.encode!(%{
      "status" => true,
      "subtitles" => [
        %{
          "release_name" => "The.Matrix.1999.1080p.BluRay",
          "name" => "The Matrix",
          "lang" => "english",
          "author" => "someone",
          "url" => "/subtitle/3197651-3213944.zip",
          "subtitlePage" => "https://subdl.com/subtitle/x",
          "season" => nil,
          "episode" => nil,
          "language" => "EN",
          "hi" => false,
          "episode_from" => nil,
          "episode_end" => 0,
          "full_season" => false
        }
      ]
    })
  end

  test "searches by tmdb id and sends the api key", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/api/v1/subtitles", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.query_params["api_key"] == "test-key"
      assert conn.query_params["tmdb_id"] == "603"
      assert conn.query_params["type"] == "movie"
      assert conn.query_params["languages"] == "EN"

      Plug.Conn.resp(conn, 200, search_response())
    end)

    params = %{languages: "en", tmdb_id: "603", media_type: "movie"}

    assert {:ok, [result]} = SubDL.search(config, params)

    assert result.language == "en"
    assert result.file_name == "The.Matrix.1999.1080p.BluRay"
    assert result.hearing_impaired == false
    assert result.moviehash_match == false
    assert result.file_id =~ "3197651-3213944"
  end

  test "sends season and episode for a tv search", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/api/v1/subtitles", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.query_params["type"] == "tv"
      assert conn.query_params["season_number"] == "2"
      assert conn.query_params["episode_number"] == "5"

      Plug.Conn.resp(conn, 200, search_response())
    end)

    params = %{
      languages: "en",
      tmdb_id: "1396",
      media_type: "episode",
      season_number: 2,
      episode_number: 5
    }

    assert {:ok, _results} = SubDL.search(config, params)
  end

  test "returns an empty list when the API reports no results", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/api/v1/subtitles", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"status" => false, "error" => "No results"}))
    end)

    assert {:ok, []} = SubDL.search(config, %{languages: "en", tmdb_id: "0"})
  end

  test "maps a 401 to invalid credentials", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/api/v1/subtitles", fn conn ->
      Plug.Conn.resp(conn, 401, "")
    end)

    assert {:error, :invalid_credentials} =
             SubDL.search(config, %{languages: "en", tmdb_id: "603"})
  end

  test "maps a 429 to rate limited", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/api/v1/subtitles", fn conn ->
      Plug.Conn.resp(conn, 429, "")
    end)

    assert {:error, :rate_limited} = SubDL.search(config, %{languages: "en", tmdb_id: "603"})
  end

  test "errors without an imdb or tmdb id", %{config: config} do
    assert {:error, :insufficient_search_criteria} = SubDL.search(config, %{languages: "en"})
  end

  test "downloads a zip and returns the subtitle inside it", %{bypass: bypass, config: config} do
    {:ok, {_name, zip}} =
      :zip.create(~c"s.zip", [{~c"Movie.srt", "1\n00:00:01,000 --> 00:00:02,000\nhello\n"}], [
        :memory
      ])

    Bypass.expect_once(bypass, "GET", "/subtitle/123-456.zip", fn conn ->
      Plug.Conn.resp(conn, 200, zip)
    end)

    assert {:ok, content} = SubDL.download(config, %{file_id: "/subtitle/123-456.zip"})
    assert content =~ "hello"
  end

  test "passes through a bare subtitle that is not zipped", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/subtitle/plain.srt", fn conn ->
      Plug.Conn.resp(conn, 200, "1\n00:00:01,000 --> 00:00:02,000\nhello\n")
    end)

    assert {:ok, content} = SubDL.download(config, %{file_id: "/subtitle/plain.srt"})
    assert content =~ "hello"
  end

  test "surfaces an archive holding no subtitle", %{bypass: bypass, config: config} do
    {:ok, {_name, zip}} = :zip.create(~c"e.zip", [{~c"readme.txt", "nope"}], [:memory])

    Bypass.expect_once(bypass, "GET", "/subtitle/empty.zip", fn conn ->
      Plug.Conn.resp(conn, 200, zip)
    end)

    assert {:error, :no_subtitle_in_archive} =
             SubDL.download(config, %{file_id: "/subtitle/empty.zip"})
  end

  test "rejects a config with no api key" do
    assert {:error, _message} = SubDL.validate_config(%{type: :subdl, api_key: nil})
  end

  test "accepts a config with an api key" do
    config = %{type: :subdl, api_key: "k"}
    assert {:ok, ^config} = SubDL.validate_config(config)
  end

  test "reports limited quota with an unknown remaining count", %{config: config} do
    assert {:ok, quota} = SubDL.quota_info(config)

    assert quota.type == :limited
    assert quota.remaining == nil
  end

  test "declares movie and episode capabilities" do
    caps = SubDL.capabilities()

    assert :movie in caps.media_types
    assert :episode in caps.media_types
    assert caps.requires_credentials == true
    assert caps.quota == :limited
  end
end
