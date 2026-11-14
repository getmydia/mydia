defmodule MetadataRelay.Backup.MembersTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias MetadataRelay.Backup
  alias MetadataRelay.Backup.{Member, Store, Vault}
  alias MetadataRelay.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    dir = Path.join(System.tmp_dir!(), "backup_members_#{System.unique_integer([:positive])}")
    previous = Application.fetch_env!(:metadata_relay, :backup)
    Application.put_env(:metadata_relay, :backup, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:metadata_relay, :backup, previous)
      File.rm_rf(dir)
    end)

    :ok
  end

  defp signer, do: :crypto.strong_rand_bytes(32)

  defp slot_id(s),
    do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp box(s), do: :crypto.hash(:sha256, "box" <> s)
  defp hash(h), do: Base.encode16(:crypto.hash(:sha256, h), case: :lower)

  defp create do
    s = signer()
    r = signer()
    h = :crypto.strong_rand_bytes(32)

    {:ok, vault} =
      Backup.create_vault(%{
        vault_id: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        signer: s,
        slot_id: slot_id(s),
        envelope: "env-1",
        box_pub: box(s),
        recovery_box_pub: box(r),
        recovery_signer: r,
        recovery_slot_id: slot_id(r),
        recovery_envelope: "renv-1",
        lookup_hash: hash(h)
      })

    %{vault: vault, signer: s, recovery: r, handle: h}
  end

  defp change(extra) do
    Map.merge(
      %{expected_epoch: 1, new_epoch: 1, add: [], remove: [], envelopes: %{}, recovery: nil},
      Enum.into(extra, %{})
    )
  end

  defp add_device(%{vault: vault, signer: s}, new) do
    Backup.update_members(
      vault,
      s,
      change(
        add: [%{signer: new, slot_id: slot_id(new), box_pub: box(new)}],
        envelopes: %{new => "env-new"}
      )
    )
  end

  defp envelope_of(vault, s) do
    {:ok, m, _} = Backup.manifest(vault, s)
    m.envelope
  end

  test "adds a member at the same epoch" do
    v = create()
    new = signer()
    assert {:ok, 1} = add_device(v, new)
    assert Backup.member?(v.vault, new)
    assert envelope_of(v.vault, new) == "env-new"
    assert envelope_of(v.vault, v.signer) == "env-1"
  end

  test "the recovery signer may add a member" do
    v = create()
    new = signer()

    assert {:ok, 1} =
             Backup.update_members(
               v.vault,
               v.recovery,
               change(
                 add: [%{signer: new, slot_id: slot_id(new), box_pub: box(new)}],
                 envelopes: %{new => "e"}
               )
             )
  end

  test "a non member is :not_member" do
    v = create()
    assert {:error, :not_member} = add_device(%{v | signer: signer()}, signer())
  end

  test "an add without exactly its envelope is :invalid" do
    v = create()
    new = signer()

    assert {:error, :invalid} =
             Backup.update_members(
               v.vault,
               v.signer,
               change(add: [%{signer: new, slot_id: slot_id(new), box_pub: box(new)}])
             )

    refute Backup.member?(v.vault, new)
  end

  test "rotation with the full envelope set bumps the epoch and replaces every envelope" do
    v = create()
    new = signer()
    {:ok, 1} = add_device(v, new)

    assert {:ok, 2} =
             Backup.update_members(
               v.vault,
               v.signer,
               change(
                 new_epoch: 2,
                 envelopes: %{v.signer => "e2-a", new => "e2-b", v.recovery => "e2-r"}
               )
             )

    assert envelope_of(v.vault, v.signer) == "e2-a"
    assert envelope_of(v.vault, new) == "e2-b"
    assert envelope_of(v.vault, v.recovery) == "e2-r"

    assert Repo.get!(Vault, v.vault).recovery_envelope ==
             Base.url_encode64("e2-r", padding: false)

    assert {:ok, m, _} = Backup.manifest(v.vault, v.signer)
    assert m.epoch == 2
  end

  test "rotation missing one envelope is :invalid and changes nothing" do
    v = create()

    assert {:error, :invalid} =
             Backup.update_members(
               v.vault,
               v.signer,
               change(new_epoch: 2, envelopes: %{v.signer => "x"})
             )

    assert {:ok, %{epoch: 1}, _} = Backup.manifest(v.vault, v.signer)
    assert envelope_of(v.vault, v.signer) == "env-1"
  end

  test "stale expected_epoch is :conflict; a wrong new_epoch is :invalid" do
    v = create()

    assert {:error, :conflict} =
             Backup.update_members(v.vault, v.signer, change(expected_epoch: 5, new_epoch: 5))

    assert {:error, :invalid} =
             Backup.update_members(v.vault, v.signer, change(new_epoch: 3))
  end

  test "sequential racers: the loser gets :conflict and succeeds after retrying" do
    v = create()
    a = signer()
    b = signer()

    rotate = fn extra_signer, epoch, others ->
      Backup.update_members(
        v.vault,
        v.signer,
        change(
          expected_epoch: epoch,
          new_epoch: epoch + 1,
          add: [
            %{signer: extra_signer, slot_id: slot_id(extra_signer), box_pub: box(extra_signer)}
          ],
          envelopes: Map.merge(%{v.signer => "e", v.recovery => "r", extra_signer => "n"}, others)
        )
      )
    end

    assert {:ok, 2} = rotate.(a, 1, %{})
    assert {:error, :conflict} = rotate.(b, 1, %{})
    assert {:ok, 3} = rotate.(b, 2, %{a => "n2"})
  end

  test "removing a member deletes its slot row and file, and member? turns false" do
    v = create()
    new = signer()
    {:ok, 1} = add_device(v, new)
    {:ok, 1} = Backup.put_slot(v.vault, new, slot_id(new), "ciphertext", nil, 1)
    path = Store.slot_path(v.vault, slot_id(new), 1)
    assert {:ok, _} = Store.read(path)

    assert {:ok, 2} =
             Backup.update_members(
               v.vault,
               v.signer,
               change(
                 new_epoch: 2,
                 remove: [new],
                 envelopes: %{v.signer => "a", v.recovery => "r"}
               )
             )

    refute Backup.member?(v.vault, new)
    assert {:error, :not_found} = Backup.get_slot(v.vault, slot_id(new))
    assert {:error, :enoent} = Store.read(path)
    assert Repo.aggregate(from(m in Member, where: m.vault_id == ^v.vault), :count) == 2
  end

  test "removing without rotation is :invalid" do
    v = create()
    new = signer()
    {:ok, 1} = add_device(v, new)

    assert {:error, :invalid} = Backup.update_members(v.vault, v.signer, change(remove: [new]))
    assert Backup.member?(v.vault, new)
  end

  test "a member may remove itself" do
    v = create()
    new = signer()
    {:ok, 1} = add_device(v, new)

    assert {:ok, 2} =
             Backup.update_members(
               v.vault,
               new,
               change(
                 new_epoch: 2,
                 remove: [new],
                 envelopes: %{v.signer => "a", v.recovery => "r"}
               )
             )

    refute Backup.member?(v.vault, new)
  end

  test "the recovery signer cannot be removed without a replacement" do
    v = create()

    assert {:error, :invalid} =
             Backup.update_members(
               v.vault,
               v.signer,
               change(new_epoch: 2, remove: [v.recovery], envelopes: %{v.signer => "a"})
             )

    assert Backup.member?(v.vault, v.recovery)
  end

  test "recovery replacement swaps signer, envelope and lookup handle atomically" do
    v = create()
    r2 = signer()
    h2 = :crypto.strong_rand_bytes(32)

    assert {:ok, 2} =
             Backup.update_members(
               v.vault,
               v.signer,
               change(
                 new_epoch: 2,
                 envelopes: %{v.signer => "a"},
                 recovery: %{
                   signer: r2,
                   slot_id: slot_id(r2),
                   box_pub: box(r2),
                   envelope: "r2-env",
                   lookup_hash: hash(h2)
                 }
               )
             )

    assert {:error, :not_found} = Backup.lookup(v.handle)
    assert {:ok, vault} = Backup.lookup(h2)
    assert vault == v.vault
    refute Backup.member?(v.vault, v.recovery)
    assert Backup.member?(v.vault, r2)
    assert {:ok, m, _} = Backup.manifest(v.vault, r2)
    assert m.recovery_signer == r2
    assert m.envelope == "r2-env"
  end

  test "recovery replacement with a taken lookup hash is :invalid and rolls back" do
    v = create()
    other = create()
    r2 = signer()

    assert {:error, :invalid} =
             Backup.update_members(
               v.vault,
               v.signer,
               change(
                 new_epoch: 2,
                 envelopes: %{v.signer => "a"},
                 recovery: %{
                   signer: r2,
                   slot_id: slot_id(r2),
                   box_pub: box(r2),
                   envelope: "x",
                   lookup_hash: hash(other.handle)
                 }
               )
             )

    assert {:ok, %{epoch: 1}, _} = Backup.manifest(v.vault, v.signer)
    assert Backup.member?(v.vault, v.recovery)
    refute Backup.member?(v.vault, r2)
  end

  test "an add with a 31-byte box_pub is :invalid" do
    v = create()
    new = signer()

    assert {:error, :invalid} =
             Backup.update_members(
               v.vault,
               v.signer,
               change(
                 add: [%{signer: new, slot_id: slot_id(new), box_pub: <<0::248>>}],
                 envelopes: %{new => "e"}
               )
             )

    refute Backup.member?(v.vault, new)
  end

  test "a added member's box_pub appears in the manifest" do
    v = create()
    new = signer()
    {:ok, 1} = add_device(v, new)
    {:ok, m, _} = Backup.manifest(v.vault, v.signer)
    entry = Enum.find(m.members, &(&1.signer == new))
    assert entry.box_pub == box(new)
    refute entry.recovery?
    assert Enum.find(m.members, & &1.recovery?).signer == v.recovery
  end

  test "a recovery replacement with the current recovery signer is :invalid" do
    v = create()
    h2 = :crypto.strong_rand_bytes(32)

    assert {:error, :invalid} =
             Backup.update_members(
               v.vault,
               v.signer,
               change(
                 new_epoch: 2,
                 envelopes: %{v.signer => "a"},
                 recovery: %{
                   signer: v.recovery,
                   slot_id: slot_id(v.recovery),
                   box_pub: box(v.recovery),
                   envelope: "x",
                   lookup_hash: hash(h2)
                 }
               )
             )

    assert {:ok, %{epoch: 1}, _} = Backup.manifest(v.vault, v.signer)
  end

  test "the 17th member is :too_many_members" do
    v = create()

    for _ <- 1..14 do
      assert {:ok, 1} = add_device(v, signer())
    end

    assert Repo.aggregate(from(m in Member, where: m.vault_id == ^v.vault), :count) == 16
    assert {:error, :too_many_members} = add_device(v, signer())
  end
end
