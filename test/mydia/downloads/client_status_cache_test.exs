defmodule Mydia.Downloads.ClientStatusCacheTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.ClientStatusCache

  defp client_name, do: "fictional-client-#{System.unique_integer([:positive])}"

  test "returns the snapshot that was put, with the time it was taken" do
    name = client_name()
    fetched_at = ~U[2026-09-15 08:40:47Z]

    assert :ok = ClientStatusCache.put(name, %{"hash-a" => :status}, fetched_at)

    assert ClientStatusCache.get(name) == {%{"hash-a" => :status}, fetched_at}
  end

  test "a later put replaces the snapshot" do
    name = client_name()

    ClientStatusCache.put(name, %{"hash-a" => :old}, ~U[2026-09-15 08:40:00Z])
    ClientStatusCache.put(name, %{"hash-b" => :new}, ~U[2026-09-15 08:41:00Z])

    assert ClientStatusCache.get(name) == {%{"hash-b" => :new}, ~U[2026-09-15 08:41:00Z]}
  end

  test "returns nil for a client that never answered" do
    assert ClientStatusCache.get(client_name()) == nil
  end
end
