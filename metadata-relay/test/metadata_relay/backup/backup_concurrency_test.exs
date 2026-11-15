defmodule MetadataRelay.BackupConcurrencyTest do
  # These tests need real, overlapping database connections, so they run with
  # the Sandbox in :auto mode (no wrapping transaction) and clean up their own
  # vault. Everything else in the suite stays sandboxed.
  use ExUnit.Case, async: false

  alias MetadataRelay.Backup
  alias MetadataRelay.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    dir = Path.join(System.tmp_dir!(), "backup_conc_#{System.unique_integer([:positive])}")
    previous = Application.fetch_env!(:metadata_relay, :backup)
    Application.put_env(:metadata_relay, :backup, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:metadata_relay, :backup, previous)
      File.rm_rf(dir)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  defp box(s), do: :crypto.hash(:sha256, "box" <> s)
  defp signer, do: :crypto.strong_rand_bytes(32)

  defp slot_id(s),
    do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp create_vault(signers) do
    [first | _] = signers
    r = signer()
    h = :crypto.strong_rand_bytes(32)

    {:ok, vault} =
      Backup.create_vault(%{
        vault_id: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        signer: first,
        slot_id: slot_id(first),
        envelope: "e",
        box_pub: box(first),
        recovery_box_pub: box(r),
        recovery_signer: r,
        recovery_slot_id: slot_id(r),
        recovery_envelope: "re",
        lookup_hash: Base.encode16(:crypto.hash(:sha256, h), case: :lower)
      })

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      Backup.delete_vault(vault)
    end)

    vault
  end

  defp add_member(vault, s) do
    Repo.insert!(%MetadataRelay.Backup.Member{
      vault_id: vault,
      signer: Base.url_encode64(s, padding: false),
      slot_id: slot_id(s),
      envelope: "e",
      box_pub: box(s)
    })
  end

  test "writers to different slots of one vault all succeed" do
    signers = for _ <- 1..4, do: signer()
    vault = create_vault(signers)
    Enum.each(tl(signers), &add_member(vault, &1))

    results =
      signers
      |> Enum.map(fn s ->
        Task.async(fn -> Backup.put_slot(vault, s, slot_id(s), "body", nil, 1) end)
      end)
      |> Task.await_many(15_000)

    assert results == List.duplicate({:ok, 1}, 4)
  end

  test "two writers with the same if_match: exactly one wins" do
    s = signer()
    vault = create_vault([s])
    {:ok, 1} = Backup.put_slot(vault, s, slot_id(s), "one", nil, 1)

    results =
      ["a", "b", "c"]
      |> Enum.map(fn body ->
        Task.async(fn -> Backup.put_slot(vault, s, slot_id(s), body, 1, 1) end)
      end)
      |> Task.await_many(15_000)

    assert Enum.count(results, &(&1 == {:ok, 2})) == 1
    assert Enum.count(results, &(&1 == {:error, :precondition_failed})) == 2
    assert {:ok, body, 2} = Backup.get_slot(vault, slot_id(s))
    assert body in ["a", "b", "c"]
  end

  test "two update_members with the same expected_epoch: one wins, one conflicts" do
    s = signer()
    vault = create_vault([s])
    {:ok, %{members: members}, _} = Backup.manifest(vault, s)
    recovery = Enum.find(members, &(&1.signer != s)).signer

    results =
      [signer(), signer()]
      |> Enum.map(fn new ->
        Task.async(fn ->
          Backup.update_members(vault, s, %{
            expected_epoch: 1,
            new_epoch: 2,
            add: [%{signer: new, slot_id: slot_id(new), box_pub: box(new)}],
            remove: [],
            recovery: nil,
            envelopes: %{s => "e", recovery => "r", new => "n"}
          })
        end)
      end)
      |> Task.await_many(15_000)

    assert Enum.count(results, &(&1 == {:ok, 2})) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict})) == 1
  end

  test "a rotation committing while the manifest is read does not mix epochs" do
    s = signer()
    vault = create_vault([s])
    {:ok, %{members: members}, _} = Backup.manifest(vault, s)
    recovery = Enum.find(members, &(&1.signer != s)).signer

    rotate = fn ->
      Task.async(fn ->
        Backup.update_members(vault, s, %{
          expected_epoch: 1,
          new_epoch: 2,
          envelopes: %{s => "e2", recovery => "r2"}
        })
      end)
      |> Task.await(15_000)
      |> then(&assert(&1 == {:ok, 2}))
    end

    assert {:ok, %{epoch: 1, envelope: "e"}, _} =
             Backup.manifest(vault, s, after_member: rotate)

    assert {:ok, %{epoch: 2, envelope: "e2"}, _} = Backup.manifest(vault, s)
  end
end
