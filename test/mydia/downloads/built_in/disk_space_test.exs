defmodule Mydia.Downloads.BuiltIn.DiskSpaceTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.DiskSpace

  @busybox """
  Filesystem           1024-blocks    Used Available Capacity Mounted on
  /dev/sda1             51474044  12345678  36490000  25% /downloads
  """

  @gnu """
  Filesystem     1024-blocks      Used Available Capacity Mounted on
  /dev/nvme0n1p2   499581952 288443900 197258020      60% /tmp
  """

  defp cmd_returning(output, code \\ 0) do
    fn "df", ["-Pk", _path], _opts -> {output, code} end
  end

  describe "free_bytes/2" do
    test "parses busybox df output" do
      assert {:ok, 36_490_000 * 1024} ==
               DiskSpace.free_bytes("/downloads", cmd_returning(@busybox))
    end

    test "parses GNU df output" do
      assert {:ok, 197_258_020 * 1024} == DiskSpace.free_bytes("/tmp", cmd_returning(@gnu))
    end

    test "passes -Pk, the path and stderr_to_stdout to df" do
      cmd = fn program, args, opts ->
        send(self(), {:called, program, args, opts})
        {@gnu, 0}
      end

      assert {:ok, _} = DiskSpace.free_bytes("/data", cmd)
      assert_received {:called, "df", ["-Pk", "/data"], [stderr_to_stdout: true]}
    end

    test "returns df_failed for a missing path" do
      out = "df: /nope: No such file or directory\n"

      assert {:error, {:df_failed, 1, "df: /nope: No such file or directory"}} ==
               DiskSpace.free_bytes("/nope", cmd_returning(out, 1))
    end

    test "returns unparseable for garbage output" do
      assert {:error, {:unparseable, "garbage\n"}} =
               DiskSpace.free_bytes("/x", cmd_returning("garbage\n"))

      assert {:error, {:unparseable, _}} =
               DiskSpace.free_bytes("/x", cmd_returning("Filesystem a b c d e f\nx 1 2 3x 4 /\n"))

      assert {:error, {:unparseable, _}} = DiskSpace.free_bytes("/x", cmd_returning(""))
    end

    test "returns df_unavailable when df is not on PATH" do
      cmd = fn _, _, _ -> raise ErlangError, original: :enoent end
      assert {:error, :df_unavailable} == DiskSpace.free_bytes("/x", cmd)
    end

    test "maps other ErlangErrors to df_error" do
      cmd = fn _, _, _ -> raise ErlangError, original: :eacces end
      assert {:error, {:df_error, :eacces}} == DiskSpace.free_bytes("/x", cmd)
    end

    test "maps ArgumentError to invalid_path" do
      cmd = fn _, _, _ -> raise ArgumentError, "bad path" end
      assert {:error, {:df_error, :invalid_path}} == DiskSpace.free_bytes("/x", cmd)
    end

    test "works against the real df" do
      assert {:ok, n} = DiskSpace.free_bytes(System.tmp_dir!())
      assert n > 0
    end
  end

  describe "format_gb/1" do
    test "formats decimal GB with one decimal" do
      assert DiskSpace.format_gb(41_200_000_000) == "41.2 GB"
      assert DiskSpace.format_gb(5_000_000_000) == "5.0 GB"
      assert DiskSpace.format_gb(0) == "0.0 GB"
    end
  end
end
