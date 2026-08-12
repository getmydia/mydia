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
    test "normalizes provider results", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/v1/subtitles/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "subtitles" => [
              %{
                "file_id" => 12_345,
                "language" => "en",
                "file_name" => "Movie.2020.1080p.srt",
                "rating" => 8.5,
                "download_count" => 4200,
                "hearing_impaired" => false,
                "moviehash_match" => true
              }
            ]
          })
        )
      end)

      assert {:ok, [result]} = Relay.search(@provider, %{languages: "en", imdb_id: "0133093"})
      assert result.file_id == 12_345
      assert result.language == "en"
      assert result.moviehash_match
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
  end

  test "quota_info reports the relay as unlimited" do
    assert {:ok, %QuotaInfo{type: :unlimited, provider_type: :relay}} =
             Relay.quota_info(@provider)
  end

  test "validate_config accepts a relay with no credentials" do
    assert {:ok, _config} = Relay.validate_config(%{type: :relay})
  end
end
