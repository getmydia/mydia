defmodule MetadataRelay.P2pAccess.StoreTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias MetadataRelay.P2pAccess.Store

  setup do
    Store.init_tables()
    :ets.delete_all_objects(:p2p_sightings)
    :ets.delete_all_objects(:p2p_blocked)

    original_cap = Application.get_env(:metadata_relay, :p2p_max_sightings)
    on_exit(fn -> Application.put_env(:metadata_relay, :p2p_max_sightings, original_cap) end)

    :ok
  end

  defp endpoint_id(n), do: String.pad_leading(Integer.to_string(n, 16), 64, "0") |> String.downcase()

  test "records a first sighting with count 1" do
    id = endpoint_id(1)

    assert :ok = Store.record_sighting(id)
    assert {:ok, {first_seen, last_seen, 1}} = Store.lookup_sighting(id)
    assert first_seen == last_seen
  end

  test "increments the connection count on repeat sightings" do
    id = endpoint_id(2)

    :ok = Store.record_sighting(id)
    :ok = Store.record_sighting(id)
    :ok = Store.record_sighting(id)

    assert {:ok, {_first, _last, 3}} = Store.lookup_sighting(id)
  end

  test "preserves first_seen across repeat sightings" do
    id = endpoint_id(3)

    :ok = Store.record_sighting(id)
    {:ok, {first_seen, _, _}} = Store.lookup_sighting(id)

    :ok = Store.record_sighting(id)

    assert {:ok, {^first_seen, _, 2}} = Store.lookup_sighting(id)
  end

  test "stops recording new endpoints once the cap is reached" do
    Application.put_env(:metadata_relay, :p2p_max_sightings, 2)

    :ok = Store.record_sighting(endpoint_id(10))
    :ok = Store.record_sighting(endpoint_id(11))
    :ok = Store.record_sighting(endpoint_id(12))

    assert Store.sighting_count() == 2
    assert Store.lookup_sighting(endpoint_id(12)) == :error
  end

  test "keeps updating known endpoints after the cap is reached" do
    Application.put_env(:metadata_relay, :p2p_max_sightings, 1)

    id = endpoint_id(20)
    :ok = Store.record_sighting(id)
    :ok = Store.record_sighting(id)

    assert Store.sighting_count() == 1
    assert {:ok, {_first, _last, 2}} = Store.lookup_sighting(id)
  end
end
