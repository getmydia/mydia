defmodule Mydia.Indexers.HealthTest do
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Health
  alias Mydia.Settings

  describe "status_map/1" do
    test "reports disabled indexers as :disabled without a network call" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      {:ok, indexer} =
        Settings.create_indexer_config(%{
          name: "Disabled Indexer",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass.port}",
          api_key: "key",
          enabled: false
        })

      map = Health.status_map([indexer])
      assert map[indexer.id].status == :disabled
    end

    test "reports :unknown on cache miss without probing" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      {:ok, indexer} =
        Settings.create_indexer_config(%{
          name: "Unchecked Indexer",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass.port}",
          api_key: "key",
          enabled: true
        })

      map = Health.status_map([indexer])
      assert map[indexer.id].status == :unknown
    end
  end

  describe "paused Prowlarr indexers" do
    test "a healthy Prowlarr check carries the paused list in details" do
      start_supervised!(Health)
      bypass = Bypass.open()
      till = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601()

      Mydia.IndexerMock.mock_prowlarr_status(bypass,
        indexer_status: [%{"indexerId" => 1, "disabledTill" => till}]
      )

      Mydia.IndexerMock.mock_prowlarr_indexers(bypass)

      {:ok, indexer} =
        Settings.create_indexer_config(%{
          name: "Paused Prowlarr",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass.port}",
          api_key: "key",
          enabled: true
        })

      assert {:ok, %{status: :healthy, details: details}} =
               Health.check_health(indexer.id, force: true)

      assert [%{id: 1, name: "Fictional Tracker"}] = details.paused_indexers
    end
  end
end
