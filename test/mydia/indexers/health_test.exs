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
end
