defmodule Mydia.Subtitles.Provider.RelayTest do
  use ExUnit.Case, async: false

  alias Mydia.Subtitles.Provider.QuotaInfo
  alias Mydia.Subtitles.Provider.Relay

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:mydia, :subtitle_relay_url)

    Application.put_env(:mydia, :subtitle_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn -> Application.put_env(:mydia, :subtitle_relay_url, original) end)
    {:ok, bypass: bypass}
  end

  @provider %{id: "relay-default", name: "Mydia Relay", type: :relay}

  describe "search/2" do
    # This fixture mirrors the actual output of
    # MetadataRelay.OpenSubtitles.Handler.transform_subtitle/1
    # (metadata-relay/lib/metadata_relay/opensubtitles/handler.ex:144-167),
    # not the field names SearchResult.from_map/1 reads. The relay emits
    # "id" (not "file_id"), "release" (not "file_name"), and never emits
    # "subtitle_hash" or "moviehash_match" at all.
    test "normalizes provider results from the relay's real wire format", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/v1/subtitles/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "subtitles" => [
              %{
                "id" => 12_345,
                "language" => "en",
                "format" => "srt",
                "rating" => 8.5,
                "download_count" => 4200,
                "release" => "Movie.2020.1080p.BluRay.x264",
                "uploader" => "someuser",
                "hearing_impaired" => false,
                "foreign_parts_only" => false,
                "feature_type" => "Movie",
                "title" => "Movie",
                "year" => 2020,
                "imdb_id" => "0133093",
                "tmdb_id" => nil
              }
            ]
          })
        )
      end)

      assert {:ok, [result]} = Relay.search(@provider, %{languages: "en", imdb_id: "0133093"})

      assert result.file_id == 12_345
      assert result.language == "en"
      assert result.format == "srt"
      assert result.file_name == "Movie.2020.1080p.BluRay.x264"
      assert result.rating == 8.5
      assert result.download_count == 4200
      refute result.hearing_impaired

      # The relay never emits moviehash_match; from_map/1 defaults it false.
      refute result.moviehash_match

      # The relay never emits subtitle_hash either, so it must be
      # synthesized deterministically from (file_id, language) -- same
      # formula as Mydia.Subtitles.generate_subtitle_hash/1.
      expected_hash =
        :crypto.hash(:sha256, "12345-en") |> Base.encode16(case: :lower)

      assert result.subtitle_hash == expected_hash
    end

    test "surfaces the relay's error reason without collapsing it", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/v1/subtitles/search", fn conn ->
        Plug.Conn.resp(conn, 401, "")
      end)

      assert {:error, :authentication_failed} = Relay.search(@provider, %{languages: "en"})
    end
  end

  describe "download/2" do
    test "fetches the file content behind the relay's download URL", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/v1/subtitles/download-url/12345", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "download_url" => "http://localhost:#{bypass.port}/files/movie.en.srt",
            "file_name" => "movie.en.srt",
            "requests_used" => 10,
            "requests_remaining" => 90
          })
        )
      end)

      Bypass.expect_once(bypass, "GET", "/files/movie.en.srt", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(
          200,
          "1\r\n00:00:01,000 --> 00:00:05,000\r\nHello there\r\n\r\n"
        )
      end)

      assert {:ok, content} = Relay.download(@provider, %{file_id: 12_345})
      assert content =~ "Hello there"
    end

    test "surfaces not_found without collapsing it into a generic error", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/v1/subtitles/download-url/99999", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      assert {:error, :not_found} = Relay.download(@provider, %{file_id: 99_999})
    end

    # OpenSubtitles returns HTTP 406 when the shared relay account's daily
    # download quota is exhausted, distinct from 429 rate limiting. The
    # relay (metadata-relay/lib/metadata_relay/router.ex:938-946) propagates
    # that status verbatim, so MetadataRelay.get_download_url/2 surfaces it
    # as {:error, {:http_error, 406, body}}.
    test "maps a 406 download-quota response to :quota_exceeded", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/v1/subtitles/download-url/12345", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(406, Jason.encode!(%{"error" => "Download quota exceeded"}))
      end)

      assert {:error, :quota_exceeded} = Relay.download(@provider, %{file_id: 12_345})
    end
  end

  test "quota_info reports the relay as unlimited" do
    assert {:ok, %QuotaInfo{type: :unlimited, provider_type: :relay}} =
             Relay.quota_info(@provider)
  end

  test "validate_config accepts a relay with no credentials" do
    assert {:ok, _config} = Relay.validate_config(%{type: :relay})
  end
end
