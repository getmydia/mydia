defmodule Mydia.Indexers.ManualSearchTest do
  # Mutates :persistent_term, the adapter registry and application env.
  use Mydia.DataCase, async: false

  import Mydia.IndexersFixtures

  alias Mydia.Indexers
  alias Mydia.Indexers.Adapter.Registry
  alias Mydia.Indexers.ManualSearch

  @active_key {Mydia.Indexers.Cardigann.EngineSwitcher, :active}

  setup do
    :persistent_term.put(@active_key, :prowlarr)
    Registry.register(:cardigann, Mydia.Indexers.StubCardigannAdapter)
    Application.put_env(:mydia, :stub_cardigann_pid, self())

    on_exit(fn ->
      :persistent_term.erase(@active_key)
      Application.delete_env(:mydia, :stub_cardigann_pid)
      Indexers.register_adapters()
    end)

    cardigann_definition_fixture(%{enabled: true, type: "public"})
    :ok
  end

  test "a manual search tells the indexers it is interactive" do
    assert {:ok, [], []} = ManualSearch.run("Copper Lantern", 0, self(), "s1")
    assert_received {:stub_cardigann_opts, opts}
    assert opts[:interactive] == true
  end

  test "reports its start and each indexer's progress to the caller" do
    assert {:ok, [], []} = ManualSearch.run("Copper Lantern", 0, self(), "s2")
    assert_received {:indexer_search_started, "s2", [_ | _]}
    assert_received {:indexer_progress, "s2", _progress}
  end
end
