defmodule Mydia.Subtitles.Provider.OpenSubtitlesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.Subtitles.Provider.OpenSubtitles
  alias Mydia.Subtitles.Provider.QuotaInfo

  setup do
    bypass = Bypass.open()

    provider = %{
      id: "os-1",
      name: "My OpenSubtitles",
      type: :opensubtitles,
      username: "user@example.com",
      password: "hunter2",
      api_key: "test-api-key",
      vip_status: false,
      base_url: "http://localhost:#{bypass.port}"
    }

    {:ok, bypass: bypass, provider: provider}
  end

  # This fixture is built from the real OpenSubtitles.com API v1 shapes as
  # exercised by metadata-relay/lib/metadata_relay/opensubtitles/{client,
  # handler,auth}.ex, which talks to the live API in production -- not from
  # the task brief's guess. In particular:
  #
  #   - Login succeeds with {"token" => ..., "user" => ...} (auth.ex:140),
  #     not just a bare "token" key.
  #   - Every request carries an "Api-Key" header (application identity) in
  #     addition to the "Authorization: Bearer <jwt>" header once logged in
  #     (client.ex:41-46).
  #   - Search results nest the downloadable file's file_id inside
  #     attributes.files; the subtitle's own top-level "id" is a different,
  #     separate identifier used only as a fallback (handler.ex's
  #     transform_subtitle/1 and get_file_id/1).
  #   - Download returns a temporary {"link", "file_name", "requests",
  #     "remaining"} envelope (handler.ex:90-104); the Provider.download/2
  #     contract requires the raw file *content*, so the link must be
  #     fetched separately (see Mydia.Subtitles.Provider.Relay.fetch_content/1).
  defp stub_login(bypass) do
    Bypass.stub(bypass, "POST", "/api/v1/login", fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw_body) == %{
               "username" => "user@example.com",
               "password" => "hunter2"
             }

      assert ["test-api-key"] = Plug.Conn.get_req_header(conn, "api-key")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "token" => "jwt-token",
          "user" => %{"allowed_downloads" => 200, "level" => "Sub leecher", "vip" => false}
        })
      )
    end)
  end

  describe "search/2" do
    test "returns normalized results, preferring the file's own file_id",
         %{bypass: bypass, provider: provider} do
      stub_login(bypass)

      Bypass.expect_once(bypass, "GET", "/api/v1/subtitles", fn conn ->
        assert ["Bearer jwt-token"] = Plug.Conn.get_req_header(conn, "authorization")
        assert conn.query_params["languages"] == "en"
        assert conn.query_params["imdb_id"] == "0133093"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{
                "id" => "3162",
                "type" => "subtitle",
                "attributes" => %{
                  "language" => "en",
                  "format" => "srt",
                  "ratings" => 8.0,
                  "download_count" => 900,
                  "release" => "Movie.2020.1080p.BluRay.x264",
                  "hearing_impaired" => false,
                  "moviehash_match" => false,
                  "files" => [
                    %{"file_id" => 777, "cd_number" => 1, "file_name" => "Movie.srt"}
                  ]
                }
              }
            ]
          })
        )
      end)

      assert {:ok, [result]} =
               OpenSubtitles.search(provider, %{languages: "en", imdb_id: "0133093"})

      assert result.file_id == 777
      assert result.language == "en"
      assert result.format == "srt"
      assert result.file_name == "Movie.srt"
      assert result.rating == 8.0
      assert result.download_count == 900
      refute result.hearing_impaired
      refute result.moviehash_match
      assert is_binary(result.subtitle_hash)
    end

    # Regression test for a real bug in the task brief's draft: its
    # flatten_entry/1 dropped any search result whose attributes.files list
    # was empty or absent instead of falling back to the entry's top-level
    # subtitle id, the way MetadataRelay.OpenSubtitles.Handler.get_file_id/1
    # does. Silently dropping results is worse than a less-precise id.
    test "falls back to the top-level subtitle id when attributes.files is empty",
         %{bypass: bypass, provider: provider} do
      stub_login(bypass)

      Bypass.expect_once(bypass, "GET", "/api/v1/subtitles", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{"id" => "9988", "attributes" => %{"language" => "en", "files" => []}}
            ]
          })
        )
      end)

      assert {:ok, [result]} = OpenSubtitles.search(provider, %{languages: "en"})
      assert result.file_id == "9988"
    end

    test "surfaces a failed login as :authentication_failed", %{
      bypass: bypass,
      provider: provider
    } do
      Bypass.expect_once(bypass, "POST", "/api/v1/login", fn conn ->
        Plug.Conn.resp(conn, 401, Jason.encode!(%{"message" => "invalid credentials"}))
      end)

      assert {:error, :authentication_failed} =
               OpenSubtitles.search(provider, %{languages: "en"})
    end

    test "never logs the user's password, even on a failed login",
         %{bypass: bypass, provider: provider} do
      Bypass.expect_once(bypass, "POST", "/api/v1/login", fn conn ->
        Plug.Conn.resp(conn, 401, Jason.encode!(%{"message" => "invalid credentials"}))
      end)

      log =
        capture_log(fn ->
          assert {:error, :authentication_failed} =
                   OpenSubtitles.search(provider, %{languages: "en"})
        end)

      refute log =~ provider.password
    end
  end

  describe "download/2" do
    test "fetches the raw file content behind the temporary link, not the link itself",
         %{bypass: bypass, provider: provider} do
      stub_login(bypass)

      Bypass.expect_once(bypass, "POST", "/api/v1/download", fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{"file_id" => 777}
        assert ["Bearer jwt-token"] = Plug.Conn.get_req_header(conn, "authorization")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "link" => "http://localhost:#{bypass.port}/files/movie.en.srt",
            "file_name" => "movie.en.srt",
            "requests" => 10,
            "remaining" => 90
          })
        )
      end)

      Bypass.expect_once(bypass, "GET", "/files/movie.en.srt", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "1\r\n00:00:01,000 --> 00:00:05,000\r\nHello there\r\n\r\n")
      end)

      assert {:ok, content} = OpenSubtitles.download(provider, %{file_id: 777})
      assert content =~ "Hello there"
    end

    # OpenSubtitles returns HTTP 406 when the account's daily download quota
    # is exhausted. This is distinct from 429 rate limiting (see the test
    # below) and must not be collapsed into it -- Task 7's fallback chain
    # reports per-provider status and needs to tell the two apart.
    test "maps a 406 download-quota response to :quota_exceeded",
         %{bypass: bypass, provider: provider} do
      stub_login(bypass)

      Bypass.expect_once(bypass, "POST", "/api/v1/download", fn conn ->
        Plug.Conn.resp(conn, 406, Jason.encode!(%{"message" => "download limit reached"}))
      end)

      assert {:error, :quota_exceeded} = OpenSubtitles.download(provider, %{file_id: 777})
    end

    test "maps a 429 response to :rate_limited, not :quota_exceeded",
         %{bypass: bypass, provider: provider} do
      stub_login(bypass)

      Bypass.expect_once(bypass, "POST", "/api/v1/download", fn conn ->
        Plug.Conn.resp(conn, 429, Jason.encode!(%{"message" => "too many requests"}))
      end)

      assert {:error, :rate_limited} = OpenSubtitles.download(provider, %{file_id: 777})
    end
  end

  test "quota_info reads the user endpoint", %{bypass: bypass, provider: provider} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "GET", "/api/v1/infos/user", fn conn ->
      assert ["Bearer jwt-token"] = Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "downloads_count" => 8,
            "allowed_downloads" => 200,
            "remaining_downloads" => 192,
            "vip" => false
          }
        })
      )
    end)

    assert {:ok, %QuotaInfo{remaining: 192, total: 200, vip: false}} =
             OpenSubtitles.quota_info(provider)
  end

  test "validate_config rejects missing credentials" do
    assert {:error, _reason} = OpenSubtitles.validate_config(%{type: :opensubtitles})
  end

  test "validate_config accepts a full username/password/api_key config" do
    config = %{type: :opensubtitles, username: "u", password: "p", api_key: "k"}
    assert {:ok, ^config} = OpenSubtitles.validate_config(config)
  end
end
