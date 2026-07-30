defmodule Mydia.Library.MountRootsTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MountRoots

  setup do
    tmp = Path.join(System.tmp_dir!(), "mr_test_#{System.unique_integer([:positive])}")
    data = Path.join(tmp, "data")
    File.mkdir_p!(data)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp, data: data}
  end

  describe "parse_mounts/1" do
    test "parses mount point and fstype, unescaping octal spaces" do
      contents = """
      proc /proc proc rw,nosuid 0 0
      /dev/sda1 /data ext4 rw,relatime 0 0
      /dev/sdb1 /mnt/my\\040disk xfs rw 0 0
      """

      parsed = MountRoots.parse_mounts(contents)
      assert {"/proc", "proc"} in parsed
      assert {"/data", "ext4"} in parsed
      assert {"/mnt/my disk", "xfs"} in parsed
    end
  end

  describe "detect/1" do
    test "returns [] when the mounts file can't be read" do
      assert MountRoots.detect(mounts_path: "/no/such/mounts", library_paths: ["/data"]) == []
    end

    test "keeps data mounts, drops virtual and system mounts", %{data: data} do
      mounts_file = Path.join(data, "mounts")

      File.write!(mounts_file, """
      proc /proc proc rw 0 0
      tmpfs /tmp tmpfs rw 0 0
      /dev/sda1 #{data} ext4 rw 0 0
      """)

      roots = MountRoots.detect(mounts_path: mounts_file, library_paths: [data])
      assert data in roots
      refute "/proc" in roots
      refute "/tmp" in roots
    end

    test "excludes data mounts that share no top-level with a library path", %{data: data} do
      mounts_file = Path.join(data, "mounts")
      File.write!(mounts_file, "/dev/sda1 #{data} ext4 rw 0 0\n")

      # library on a different top-level segment than the mount
      assert MountRoots.detect(mounts_path: mounts_file, library_paths: ["/elsewhere/media"]) ==
               []
    end

    test "returns [] when no library paths are configured", %{data: data} do
      mounts_file = Path.join(data, "mounts")
      File.write!(mounts_file, "/dev/sda1 #{data} ext4 rw 0 0\n")

      # With nothing configured there is no meaningful mapping to suggest, and
      # keeping every mount means probing arbitrary filesystems (a wedged NFS
      # or FUSE mount then blocks the caller in the kernel).
      assert MountRoots.detect(mounts_path: mounts_file, library_paths: []) == []
    end

    test "drops a mount point that is not a directory on disk", %{data: data} do
      mounts_file = Path.join(data, "mounts")
      missing = Path.join(data, "not_mounted")

      File.write!(mounts_file, """
      /dev/sda1 #{data} ext4 rw 0 0
      /dev/sdb1 #{missing} ext4 rw 0 0
      """)

      assert MountRoots.detect(mounts_path: mounts_file, library_paths: [data]) == [data]
    end

    test "drops mounts whose probe does not answer within the budget", %{data: data} do
      mounts_file = Path.join(data, "mounts")
      slow = Path.join(data, "slow")
      File.mkdir_p!(slow)

      File.write!(mounts_file, """
      /dev/sda1 #{data} ext4 rw 0 0
      /dev/sdb1 #{slow} ext4 rw 0 0
      """)

      # Stands in for a wedged NFS/FUSE mount, where File.dir?/1 blocks in the
      # kernel indefinitely.
      probe = fn path ->
        if path == slow, do: Process.sleep(:infinity), else: File.dir?(path)
      end

      roots =
        MountRoots.detect(
          mounts_path: mounts_file,
          library_paths: [data],
          probe_fun: probe,
          probe_timeout_ms: 500
        )

      assert roots == [data]
    end
  end
end
