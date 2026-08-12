defmodule Mydia.Subtitles.Provider.RelayTest do
  use ExUnit.Case, async: false

  alias Mydia.Subtitles.Provider.QuotaInfo
  alias Mydia.Subtitles.Provider.Relay

  setup do
    bypass = Bypass.open()
    original_subtitle = Application.get_env(:mydia, :subtitle_relay_url)
    original_metadata = Application.get_env(:mydia, :metadata_relay_url)

    Application.put_env(:mydia, :subtitle_relay_url, "http://localhost:#{bypass.port}")
    Application.delete_env(:mydia, :metadata_relay_url)

    on_exit(fn ->
      if original_subtitle do
        Application.put_env(:mydia, :subtitle_relay_url, original_subtitle)
      else
        Application.delete_env(:mydia, :subtitle_relay_url)
      end

      if original_metadata do
        Application.put_env(:mydia, :metadata_relay_url, original_metadata)
      else
        Application.delete_env(:mydia, :metadata_relay_url)
      end
    end)

    {:ok, bypass: bypass}
  end

  @provider %{id: "relay-default", name: "Mydia Relay", type: :relay}

  test "search normalizes provider results", %{bypass: bypass} do
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

  test "quota_info reports the relay as unlimited" do
    assert {:ok, %QuotaInfo{type: :unlimited, provider_type: :relay}} =
             Relay.quota_info(@provider)
  end

  test "validate_config accepts a relay with no credentials" do
    assert {:ok, _config} = Relay.validate_config(%{type: :relay})
  end
end
