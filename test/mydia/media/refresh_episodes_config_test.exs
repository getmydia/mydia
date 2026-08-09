defmodule Mydia.Media.RefreshEpisodesConfigTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Media

  # REGRESSION: refresh_episodes_for_tv_show/2 previously ignored opts[:config]
  # and always called Metadata.default_relay_config/0. Callers that inject a
  # Bypass (MediaAddHelpersTest, media_controller manual match) therefore hit
  # the real relay. When the fabricated tvdb_id happened to resolve, episode
  # translation enrichment ran with Task.async_stream timeout: :infinity and
  # the ExUnit 60s wall clock killed the test — the flaky CI failure on
  # master CI run 31296248692.
  describe "refresh_episodes_for_tv_show/2 opts[:config]" do
    test "uses the injected relay config instead of the global default" do
      bypass = Bypass.open()
      tvdb_id = System.unique_integer([:positive])
      hits = :atomics.new(1, signed: false)

      Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        :atomics.add(hits, 1, 1)

        body = %{
          "data" => %{
            "id" => tvdb_id,
            "tvdb_id" => tvdb_id,
            "name" => "Config Injection Show",
            "overview" => "x",
            "first_air_date" => "2019-01-01",
            "genres" => [],
            "seasons" => []
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Config Injection Show",
          year: 2019,
          tvdb_id: tvdb_id,
          metadata_source: :tvdb
        })

      assert {:ok, 0} = Media.refresh_episodes_for_tv_show(item, config: config)
      assert :atomics.get(hits, 1) >= 1
    end
  end

  describe "create_media_item/2 opts[:config]" do
    test "forwards the injected config into the automatic episode refresh" do
      bypass = Bypass.open()
      tvdb_id = System.unique_integer([:positive])
      hits = :atomics.new(1, signed: false)

      Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        :atomics.add(hits, 1, 1)

        body = %{
          "data" => %{
            "id" => tvdb_id,
            "tvdb_id" => tvdb_id,
            "name" => "Create Forward Show",
            "overview" => "x",
            "first_air_date" => "2019-01-01",
            "genres" => [],
            "seasons" => []
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      assert {:ok, _item} =
               Media.create_media_item(
                 %{
                   type: "tv_show",
                   title: "Create Forward Show",
                   year: 2019,
                   tvdb_id: tvdb_id,
                   metadata_source: :tvdb,
                   monitored: true
                 },
                 config: config
               )

      assert :atomics.get(hits, 1) >= 1
    end
  end
end
