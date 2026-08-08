defmodule MetadataRelay.P2pAccess.SchemaTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias MetadataRelay.P2pAccess.{Block, Sighting}
  alias MetadataRelay.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  @endpoint_id String.duplicate("ab", 32)

  test "persists and reads back a sighting" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      Repo.insert(%Sighting{
        endpoint_id: @endpoint_id,
        first_seen: now,
        last_seen: now,
        conn_count: 3
      })

    assert %Sighting{conn_count: 3} = Repo.get(Sighting, @endpoint_id)
  end

  test "persists and reads back a block" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      Repo.insert(%Block{
        endpoint_id: @endpoint_id,
        reason: "bandwidth abuse",
        blocked_at: now
      })

    assert %Block{reason: "bandwidth abuse"} = Repo.get(Block, @endpoint_id)
  end
end
