defmodule Mydia.Downloads.BuiltIn.DiskSpace do
  @moduledoc """
  Measures free space on the built-in torrent client's download volume.

  Shells out to `df -Pk`, which both GNU coreutils (dev, CI) and busybox
  (Alpine, production) support. `-P` keeps each filesystem on one line, so
  the data row is always the last line and "Available" the fourth column.
  """

  @type cmd :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @doc """
  Free bytes available to unprivileged writers on the volume holding `path`.

  `cmd` is injectable for tests and defaults to `System.cmd/3`.
  """
  @spec free_bytes(Path.t(), cmd()) :: {:ok, non_neg_integer()} | {:error, term()}
  def free_bytes(path, cmd \\ &System.cmd/3) do
    case cmd.("df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} -> parse(output)
      {output, code} -> {:error, {:df_failed, code, String.trim(output)}}
    end
  rescue
    e in ErlangError ->
      case e.original do
        :enoent -> {:error, :df_unavailable}
        _ -> reraise e, __STACKTRACE__
      end
  end

  @doc "Formats bytes as decimal gigabytes with one decimal, e.g. `\"41.2 GB\"`."
  @spec format_gb(number()) :: String.t()
  def format_gb(bytes) do
    "#{:erlang.float_to_binary(bytes / 1_000_000_000, decimals: 1)} GB"
  end

  defp parse(output) do
    with line when is_binary(line) <- last_line(output),
         [_fs, _blocks, _used, available | _] <- String.split(line),
         {kb, ""} when kb >= 0 <- Integer.parse(available) do
      {:ok, kb * 1024}
    else
      _ -> {:error, {:unparseable, output}}
    end
  end

  defp last_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
  end
end
