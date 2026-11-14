defmodule MetadataRelay.Backup.StoreTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.Backup.Store

  @vault String.duplicate("a1", 16)
  @other_vault String.duplicate("b2", 16)
  @slot "0123456789abcdef"

  setup do
    dir = Path.join(System.tmp_dir!(), "backup_#{System.unique_integer([:positive])}")
    previous = Application.fetch_env!(:metadata_relay, :backup)
    Application.put_env(:metadata_relay, :backup, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:metadata_relay, :backup, previous)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "write then read round-trips bytes" do
    data = :crypto.strong_rand_bytes(1024)
    path = Store.slot_path(@vault, @slot, 3)

    assert path == "#{@vault}/#{@slot}-3.bin"
    assert :ok = Store.write(path, data)
    assert {:ok, ^data} = Store.read(path)
    assert {:error, :enoent} = Store.read(Store.slot_path(@vault, @slot, 4))
  end

  test "write leaves no .tmp file behind", %{dir: dir} do
    :ok = Store.write(Store.slot_path(@vault, @slot, 1), "x")
    assert Path.wildcard(Path.join(dir, "**/*.tmp")) == []
  end

  test "delete removes one file and tolerates a missing one" do
    path = Store.slot_path(@vault, @slot, 1)
    :ok = Store.write(path, "x")
    assert :ok = Store.delete(path)
    assert {:error, :enoent} = Store.read(path)
    assert :ok = Store.delete(path)
  end

  test "delete_vault_dir removes every file of that vault only" do
    mine = [Store.slot_path(@vault, @slot, 1), Store.slot_path(@vault, "fedcba9876543210", 2)]
    theirs = Store.slot_path(@other_vault, @slot, 1)
    Enum.each(mine, &Store.write(&1, "a"))
    :ok = Store.write(theirs, "b")

    assert :ok = Store.delete_vault_dir(@vault)

    Enum.each(mine, fn path -> assert {:error, :enoent} = Store.read(path) end)
    assert {:ok, "b"} = Store.read(theirs)
    assert :ok = Store.delete_vault_dir(@vault)
  end

  test "slot_path and delete_vault_dir reject ids that are not lowercase hex" do
    for bad <- ["../etc", "ABCDEF", "", "a/b", "zz"] do
      assert_raise ArgumentError, fn -> Store.slot_path(bad, @slot, 1) end
      assert_raise ArgumentError, fn -> Store.slot_path(@vault, bad, 1) end
      assert_raise ArgumentError, fn -> Store.delete_vault_dir(bad) end
    end

    assert_raise ArgumentError, fn -> Store.slot_path(@vault, @slot, "1") end
  end
end
