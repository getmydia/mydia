defmodule MetadataRelay.Backup.SweepTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias MetadataRelay.Backup
  alias MetadataRelay.Backup.{Store, Vault}
  alias MetadataRelay.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    dir = Path.join(System.tmp_dir!(), "backup_sweep_#{System.unique_integer([:positive])}")
    previous = Application.fetch_env!(:metadata_relay, :backup)
    Application.put_env(:metadata_relay, :backup, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:metadata_relay, :backup, previous)
      File.rm_rf(dir)
    end)

    :ok
  end

  defp slot_id(s),
    do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp create do
    s = :crypto.strong_rand_bytes(32)
    r = :crypto.strong_rand_bytes(32)

    {:ok, id} =
      Backup.create_vault(%{
        signer: s,
        slot_id: slot_id(s),
        envelope: "e",
        box_pub: :crypto.strong_rand_bytes(32),
        recovery_signer: r,
        recovery_slot_id: slot_id(r),
        recovery_envelope: "r",
        recovery_box_pub: :crypto.strong_rand_bytes(32),
        lookup_hash: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      })

    {:ok, 1} = Backup.put_slot(id, s, slot_id(s), "cipher", nil, 1)
    id
  end

  defp days_ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400) |> DateTime.truncate(:microsecond)

  defp set(id, fields), do: Repo.update_all(from(v in Vault, where: v.id == ^id), set: fields)

  defp dir(id), do: Path.join(Store.root(), id)

  test "a vault idle for 181 days goes with its files, 179 days stays" do
    old = create()
    fresh = create()
    set(old, last_write_at: days_ago(181))
    set(fresh, last_write_at: days_ago(179))
    assert File.dir?(dir(old))

    assert {:ok, 1} = Backup.sweep()

    refute Repo.get(Vault, old)
    refute File.exists?(dir(old))
    assert Repo.get(Vault, fresh)
    assert File.dir?(dir(fresh))
  end

  test "a vault never written falls back to inserted_at" do
    old = create()
    set(old, last_write_at: nil, inserted_at: days_ago(200))
    assert {:ok, 1} = Backup.sweep()
    refute Repo.get(Vault, old)

    young = create()
    set(young, last_write_at: nil, inserted_at: days_ago(10))
    assert {:ok, 0} = Backup.sweep()
    assert Repo.get(Vault, young)
  end

  test "sweep/1 takes a clock" do
    id = create()
    later = DateTime.add(DateTime.utc_now(), 181 * 86_400)
    assert {:ok, 1} = Backup.sweep(later)
    refute Repo.get(Vault, id)
  end
end
