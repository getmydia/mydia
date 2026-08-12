defmodule Mydia.Subtitles.Provider.OpenSubtitlesTest do
  use ExUnit.Case, async: true

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

  defp stub_login(bypass) do
    Bypass.stub(bypass, "POST", "/api/v1/login", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"token" => "jwt-token", "status" => 200}))
    end)
  end

  test "search returns normalized results", %{bypass: bypass, provider: provider} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "GET", "/api/v1/subtitles", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "data" => [
            %{
              "attributes" => %{
                "language" => "en",
                "ratings" => 8.0,
                "download_count" => 900,
                "hearing_impaired" => false,
                "moviehash_match" => false,
                "files" => [%{"file_id" => 777, "file_name" => "Movie.srt"}]
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
  end

  test "download returns the file link", %{bypass: bypass, provider: provider} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "POST", "/api/v1/download", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"link" => "https://dl.example.com/abc.srt", "remaining" => 42})
      )
    end)

    assert {:ok, "https://dl.example.com/abc.srt"} =
             OpenSubtitles.download(provider, %{file_id: 777})
  end

  test "reports quota exhaustion distinctly", %{bypass: bypass, provider: provider} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "POST", "/api/v1/download", fn conn ->
      Plug.Conn.resp(conn, 406, Jason.encode!(%{"message" => "download limit reached"}))
    end)

    assert {:error, :quota_exceeded} = OpenSubtitles.download(provider, %{file_id: 777})
  end

  test "quota_info reads the user endpoint", %{bypass: bypass, provider: provider} do
    stub_login(bypass)

    Bypass.expect_once(bypass, "GET", "/api/v1/infos/user", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "data" => %{"downloads_count" => 8, "allowed_downloads" => 200, "vip" => false}
        })
      )
    end)

    assert {:ok, %QuotaInfo{remaining: 192, total: 200, vip: false}} =
             OpenSubtitles.quota_info(provider)
  end

  test "validate_config rejects missing credentials" do
    assert {:error, _reason} = OpenSubtitles.validate_config(%{type: :opensubtitles})
  end
end
