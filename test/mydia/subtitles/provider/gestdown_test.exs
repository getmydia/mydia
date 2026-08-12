defmodule Mydia.Subtitles.Provider.GestdownTest do
  use ExUnit.Case, async: true

  alias Mydia.Subtitles.Provider.Gestdown

  setup do
    bypass = Bypass.open()
    config = %{name: "Gestdown", type: :gestdown, base_url: "http://localhost:#{bypass.port}"}

    {:ok, bypass: bypass, config: config}
  end

  defp show_response do
    Jason.encode!(%{
      "shows" => [
        %{
          "id" => "31ffb6ce-c000-4079-8912-b3f72057baed",
          "name" => "Breaking Bad",
          "tvDbId" => 81_189,
          "tmdbId" => 1396
        }
      ]
    })
  end

  defp subtitles_response do
    Jason.encode!(%{
      "matchingSubtitles" => [
        %{
          "subtitleId" => "bf58c008-464e-4082-9293-8b9fd0894859",
          "version" => "Bluray-CtrlHD",
          "completed" => true,
          "hearingImpaired" => false,
          "downloadUri" => "/subtitles/download/bf58c008-464e-4082-9293-8b9fd0894859",
          "language" => "English",
          "downloadCount" => 492
        },
        %{
          "subtitleId" => "incomplete-one",
          "version" => "WIP",
          "completed" => false,
          "hearingImpaired" => false,
          "downloadUri" => "/subtitles/download/incomplete-one",
          "language" => "English",
          "downloadCount" => 3
        }
      ],
      "episode" => %{"season" => 1, "number" => 1, "title" => "Pilot"}
    })
  end

  test "searches by tvdb id, season and episode", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/shows/external/tvdb/81189", fn conn ->
      Plug.Conn.resp(conn, 200, show_response())
    end)

    Bypass.expect_once(
      bypass,
      "GET",
      "/subtitles/get/31ffb6ce-c000-4079-8912-b3f72057baed/1/1/English",
      fn conn -> Plug.Conn.resp(conn, 200, subtitles_response()) end
    )

    params = %{
      languages: "en",
      tvdb_id: "81189",
      media_type: "episode",
      season_number: 1,
      episode_number: 1
    }

    assert {:ok, [result]} = Gestdown.search(config, params)

    assert result.file_id == "bf58c008-464e-4082-9293-8b9fd0894859"
    assert result.language == "en"
    assert result.format == "srt"
    assert result.file_name == "Bluray-CtrlHD"
    assert result.download_count == 492
    assert result.hearing_impaired == false
    assert result.moviehash_match == false
  end

  test "drops incomplete subtitles", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/shows/external/tvdb/81189", fn conn ->
      Plug.Conn.resp(conn, 200, show_response())
    end)

    Bypass.expect_once(
      bypass,
      "GET",
      "/subtitles/get/31ffb6ce-c000-4079-8912-b3f72057baed/1/1/English",
      fn conn -> Plug.Conn.resp(conn, 200, subtitles_response()) end
    )

    params = %{languages: "en", tvdb_id: "81189", season_number: 1, episode_number: 1}

    assert {:ok, results} = Gestdown.search(config, params)
    refute Enum.any?(results, &(&1.file_id == "incomplete-one"))
  end

  test "skips a language it cannot name and returns the rest", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/shows/external/tvdb/81189", fn conn ->
      Plug.Conn.resp(conn, 200, show_response())
    end)

    # Only English is requested upstream. "zz" has no Gestdown name, so it never
    # becomes a request. Bypass 2.1 requires a string path (not a regex).
    Bypass.expect_once(
      bypass,
      "GET",
      "/subtitles/get/31ffb6ce-c000-4079-8912-b3f72057baed/1/1/English",
      fn conn -> Plug.Conn.resp(conn, 200, subtitles_response()) end
    )

    params = %{languages: "en,zz", tvdb_id: "81189", season_number: 1, episode_number: 1}

    assert {:ok, [_result]} = Gestdown.search(config, params)
  end

  test "returns an empty list when the show is unknown", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/shows/external/tvdb/99999", fn conn ->
      Plug.Conn.resp(conn, 404, "")
    end)

    params = %{languages: "en", tvdb_id: "99999", season_number: 1, episode_number: 1}

    assert {:ok, []} = Gestdown.search(config, params)
  end

  test "errors without a tvdb id", %{config: config} do
    assert {:error, :insufficient_search_criteria} =
             Gestdown.search(config, %{languages: "en", imdb_id: "0903747"})
  end

  test "downloads the subtitle body itself, not a url", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/subtitles/download/abc", fn conn ->
      Plug.Conn.resp(conn, 200, "1\n00:00:01,000 --> 00:00:02,000\nhello\n")
    end)

    assert {:ok, content} = Gestdown.download(config, %{file_id: "abc"})
    assert content =~ "hello"
    refute content =~ "http"
  end

  test "reports unlimited quota", %{config: config} do
    assert {:ok, quota} = Gestdown.quota_info(config)
    assert quota.type == :unlimited
  end

  test "validates with no credentials", %{config: config} do
    assert {:ok, ^config} = Gestdown.validate_config(config)
  end

  test "declares episode-only capabilities keyed on tvdb id" do
    caps = Gestdown.capabilities()

    assert caps.media_types == [:episode]
    assert caps.search_keys == [:tvdb_id]
    assert caps.requires_credentials == false
    assert caps.quota == :unlimited
  end
end
