defmodule MetadataRelay.BackupTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias MetadataRelay.Backup
  alias MetadataRelay.Backup.{Member, Slot, Store, Vault}
  alias MetadataRelay.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    dir = Path.join(System.tmp_dir!(), "backup_ctx_#{System.unique_integer([:positive])}")
    previous = Application.fetch_env!(:metadata_relay, :backup)
    Application.put_env(:metadata_relay, :backup, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:metadata_relay, :backup, previous)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp signer, do: :crypto.strong_rand_bytes(32)

  defp slot_id(signer),
    do: :crypto.hash(:sha256, signer) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp box(s), do: :crypto.hash(:sha256, "box" <> s)
  defp handle, do: :crypto.strong_rand_bytes(32)
  defp vault_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp create do
    s = signer()
    r = signer()
    h = handle()

    attrs = %{
      vault_id: vault_id(),
      signer: s,
      slot_id: slot_id(s),
      envelope: "env-" <> Base.encode16(s),
      box_pub: box(s),
      recovery_box_pub: box(r),
      recovery_signer: r,
      recovery_slot_id: slot_id(r),
      recovery_envelope: "renv-" <> Base.encode16(r),
      lookup_hash: Base.encode16(:crypto.hash(:sha256, h), case: :lower)
    }

    {:ok, vault_id} = Backup.create_vault(attrs)
    %{vault: vault_id, signer: s, slot: slot_id(s), recovery: r, handle: h, attrs: attrs}
  end

  test "create keeps the client's vault id, then lookup by handle finds it" do
    v = create()
    assert v.vault == v.attrs.vault_id
    assert {:ok, vault_id} = Backup.lookup(v.handle)
    assert vault_id == v.vault
    assert {:error, :not_found} = Backup.lookup(handle())
  end

  test "second create with the same lookup hash is lookup_taken" do
    v = create()
    s = signer()
    r = signer()

    attrs = %{
      v.attrs
      | vault_id: vault_id(),
        signer: s,
        slot_id: slot_id(s),
        recovery_signer: r,
        recovery_slot_id: slot_id(r)
    }

    assert {:error, :lookup_taken} = Backup.create_vault(attrs)
  end

  test "a vault id already in use is vault_taken" do
    v = create()
    s = signer()
    r = signer()

    attrs = %{
      v.attrs
      | signer: s,
        slot_id: slot_id(s),
        recovery_signer: r,
        recovery_slot_id: slot_id(r),
        lookup_hash: Base.encode16(:crypto.hash(:sha256, handle()), case: :lower)
    }

    assert {:error, :vault_taken} = Backup.create_vault(attrs)
    assert Backup.member?(v.vault, v.signer)
    refute Backup.member?(v.vault, s)
  end

  test "create validates its inputs" do
    v = create()
    base = %{v.attrs | lookup_hash: String.duplicate("0", 63) <> "1"}
    s = signer()
    r = signer()

    ok = %{
      base
      | vault_id: vault_id(),
        signer: s,
        slot_id: slot_id(s),
        recovery_signer: r,
        recovery_slot_id: slot_id(r)
    }

    assert {:error, :invalid} = Backup.create_vault(%{ok | signer: "short"})
    assert {:error, :invalid} = Backup.create_vault(%{ok | vault_id: "ABC"})
    assert {:error, :invalid} = Backup.create_vault(%{ok | vault_id: String.duplicate("A", 32)})
    assert {:error, :invalid} = Backup.create_vault(Map.delete(ok, :vault_id))
    assert {:error, :invalid} = Backup.create_vault(%{ok | slot_id: "ZZ"})
    assert {:error, :invalid} = Backup.create_vault(%{ok | lookup_hash: "abc"})
    assert {:error, :invalid} = Backup.create_vault(%{ok | recovery_signer: s})
    assert {:error, :invalid} = Backup.create_vault(%{ok | recovery_slot_id: ok.slot_id})
    assert {:error, :invalid} = Backup.create_vault(Map.delete(ok, :envelope))
    assert {:error, :invalid} = Backup.create_vault(%{ok | box_pub: "short"})
    assert {:error, :invalid} = Backup.create_vault(%{ok | recovery_box_pub: <<0::248>>})
    assert {:ok, _} = Backup.create_vault(ok)
  end

  test "members include the recovery signer; others are not members" do
    v = create()
    assert Backup.member?(v.vault, v.signer)
    assert Backup.member?(v.vault, v.recovery)
    refute Backup.member?(v.vault, signer())
    refute Backup.member?("nothex", v.signer)
    refute Backup.member?(v.vault, "short")
  end

  test "manifest returns only the caller's envelope" do
    v = create()
    assert {:ok, m, etag} = Backup.manifest(v.vault, v.signer)
    assert is_binary(etag)
    assert m.epoch == 1
    assert m.envelope == v.attrs.envelope
    assert m.recovery_signer == v.recovery
    assert m.slots == []

    assert Enum.sort_by(m.members, & &1.slot_id) ==
             Enum.sort_by(
               [
                 %{signer: v.signer, box_pub: box(v.signer), slot_id: v.slot, recovery?: false},
                 %{
                   signer: v.recovery,
                   box_pub: box(v.recovery),
                   slot_id: v.attrs.recovery_slot_id,
                   recovery?: true
                 }
               ],
               & &1.slot_id
             )

    assert {:ok, rm, _} = Backup.manifest(v.vault, v.recovery)
    assert rm.envelope == v.attrs.recovery_envelope

    assert {:error, :not_found} = Backup.manifest(v.vault, signer())
    assert {:error, :not_found} = Backup.manifest(String.duplicate("0", 32), v.signer)
  end

  test "put_slot sequence: first write is 1, if_match advances, stale is rejected" do
    v = create()
    assert {:ok, 1} = Backup.put_slot(v.vault, v.signer, v.slot, "one", nil, 1)
    assert {:ok, 2} = Backup.put_slot(v.vault, v.signer, v.slot, "two", 1, 1)
    assert {:error, :precondition_failed} = Backup.put_slot(v.vault, v.signer, v.slot, "x", 1, 1)

    assert {:error, :precondition_failed} =
             Backup.put_slot(v.vault, v.signer, v.slot, "x", nil, 1)

    assert {:ok, "two", 2} = Backup.get_slot(v.vault, v.slot)
  end

  test "put_slot with if_match and no row is precondition_failed" do
    v = create()
    assert {:error, :precondition_failed} = Backup.put_slot(v.vault, v.signer, v.slot, "x", 1, 1)
    assert {:error, :not_found} = Backup.get_slot(v.vault, v.slot)
  end

  test "the previous seq's file is deleted and failed writes leave no file" do
    v = create()
    {:ok, 1} = Backup.put_slot(v.vault, v.signer, v.slot, "one", nil, 1)
    assert {:ok, "one"} = Store.read(Store.slot_path(v.vault, v.slot, 1))
    {:ok, 2} = Backup.put_slot(v.vault, v.signer, v.slot, "two", 1, 1)
    assert {:error, :enoent} = Store.read(Store.slot_path(v.vault, v.slot, 1))
    assert {:ok, "two"} = Store.read(Store.slot_path(v.vault, v.slot, 2))
    {:error, :precondition_failed} = Backup.put_slot(v.vault, v.signer, v.slot, "bad", 1, 1)
    assert {:ok, "two"} = Store.read(Store.slot_path(v.vault, v.slot, 2))
    assert {:error, :enoent} = Store.read(Store.slot_path(v.vault, v.slot, 3))
  end

  test "another member cannot write this slot, nor can the recovery signer or a stranger" do
    v = create()
    other = signer()
    assert {:error, :not_owner} = Backup.put_slot(v.vault, v.recovery, v.slot, "x", nil, 1)
    assert {:error, :not_owner} = Backup.put_slot(v.vault, other, v.slot, "x", nil, 1)
    assert {:error, :not_owner} = Backup.put_slot(v.vault, v.signer, slot_id(other), "x", nil, 1)
    assert {:error, :not_owner} = Backup.put_slot("nothex", v.signer, v.slot, "x", nil, 1)

    assert {:error, :not_owner} =
             Backup.put_slot(v.vault, v.signer, "../../etc/passwd", "x", nil, 1)
  end

  test "the recovery signer cannot write even its own slot" do
    v = create()

    assert {:error, :not_owner} =
             Backup.put_slot(v.vault, v.recovery, v.attrs.recovery_slot_id, "x", nil, 1)
  end

  test "get_slot retries when a write lands between the row read and the file read" do
    v = create()
    {:ok, 1} = Backup.put_slot(v.vault, v.signer, v.slot, "one", nil, 1)

    hook = fn -> {:ok, 2} = Backup.put_slot(v.vault, v.signer, v.slot, "two", 1, 1) end
    assert {:ok, "two", 2} = Backup.get_slot(v.vault, v.slot, after_row: hook)
  end

  test "get_slot is not_found when the file is gone and the seq is unchanged" do
    v = create()
    {:ok, 1} = Backup.put_slot(v.vault, v.signer, v.slot, "one", nil, 1)
    Store.delete(Store.slot_path(v.vault, v.slot, 1))
    assert {:error, :not_found} = Backup.get_slot(v.vault, v.slot)
  end

  test "size limit is 4 MiB" do
    v = create()
    big = :binary.copy(<<0>>, 4_194_305)
    assert {:error, :too_large} = Backup.put_slot(v.vault, v.signer, v.slot, big, nil, 1)
    ok = :binary.copy(<<0>>, 4_194_304)
    assert {:ok, 1} = Backup.put_slot(v.vault, v.signer, v.slot, ok, nil, 1)
    assert [%Slot{size: 4_194_304}] = Repo.all(from(s in Slot, where: s.vault_id == ^v.vault))
  end

  test "epoch mismatch is stale_epoch" do
    v = create()
    assert {:error, :stale_epoch} = Backup.put_slot(v.vault, v.signer, v.slot, "x", nil, 2)
    assert {:error, :not_found} = Backup.get_slot(v.vault, v.slot)
  end

  test "the 601st write in an hour is rate limited" do
    v = create()

    Enum.reduce(1..600, nil, fn i, prev ->
      assert {:ok, ^i} = Backup.put_slot(v.vault, v.signer, v.slot, "b#{i}", prev, 1)
      i
    end)

    assert {:error, :rate_limited} = Backup.put_slot(v.vault, v.signer, v.slot, "late", 600, 1)
    assert {:ok, "b600", 600} = Backup.get_slot(v.vault, v.slot)
  end

  test "put_slot records last_write_at and the manifest lists the slot" do
    v = create()
    before = Repo.get!(Vault, v.vault).last_write_at
    Process.sleep(5)
    {:ok, 1} = Backup.put_slot(v.vault, v.signer, v.slot, "hello", nil, 1)
    assert DateTime.compare(Repo.get!(Vault, v.vault).last_write_at, before) == :gt

    assert {:ok, m, _} = Backup.manifest(v.vault, v.recovery)
    assert [%{slot_id: slot, seq: 1, epoch: 1, size: 5, updated_at: %DateTime{}}] = m.slots
    assert slot == v.slot
  end

  test "manifest etag changes after a write" do
    v = create()
    {:ok, _, e0} = Backup.manifest(v.vault, v.signer)
    {:ok, 1} = Backup.put_slot(v.vault, v.signer, v.slot, "a", nil, 1)
    {:ok, _, e1} = Backup.manifest(v.vault, v.signer)
    {:ok, 2} = Backup.put_slot(v.vault, v.signer, v.slot, "b", 1, 1)
    {:ok, _, e2} = Backup.manifest(v.vault, v.signer)
    assert length(Enum.uniq([e0, e1, e2])) == 3
  end

  test "get_slot for an unknown slot is not_found" do
    v = create()
    assert {:error, :not_found} = Backup.get_slot(v.vault, "0123456789abcdef")
    assert {:error, :not_found} = Backup.get_slot("nothex", "0123456789abcdef")
  end

  test "delete_vault removes rows (cascade) and files", %{dir: dir} do
    v = create()
    {:ok, 1} = Backup.put_slot(v.vault, v.signer, v.slot, "a", nil, 1)
    assert File.exists?(Path.join(dir, v.vault))

    assert :ok = Backup.delete_vault(v.vault)
    assert Repo.all(from(x in Vault, where: x.id == ^v.vault)) == []
    assert Repo.all(from(m in Member, where: m.vault_id == ^v.vault)) == []
    assert Repo.all(from(s in Slot, where: s.vault_id == ^v.vault)) == []
    refute File.exists?(Path.join(dir, v.vault))
    assert {:error, :not_found} = Backup.lookup(v.handle)
    assert :ok = Backup.delete_vault(v.vault)
    assert :ok = Backup.delete_vault("nothex")
  end
end
