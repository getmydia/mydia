defmodule Mydia.Downloads.BuiltIn.DiskSpace do
  @moduledoc """
  Measures free space on the built-in torrent client's download volume.

  Shells out to `df -Pk`, which both GNU coreutils (dev, CI) and busybox
  (Alpine, production) support. `-P` keeps each filesystem on one line, so
  the data row is always the last line; "Available" is the number just before
  the Capacity percentage.
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
        other -> {:error, {:df_error, other}}
      end

    ArgumentError ->
      {:error, {:df_error, :invalid_path}}
  end

  @doc "Formats bytes as decimal gigabytes with one decimal, e.g. `\"41.2 GB\"`."
  @spec format_gb(number()) :: String.t()
  def format_gb(bytes) do
    "#{:erlang.float_to_binary(bytes / 1_000_000_000, decimals: 1)} GB"
  end

  # The filesystem source and the mount point can both contain spaces (an SMB
  # share such as `//nas/Media Files`), so the numbers are found by the
  # Capacity column that ends them rather than by position. GNU df reports a
  # negative Available on a volume past its reserved blocks; that is no room.
  @data_row ~r/(?:^|\s)(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(?:-?\d+|-)%(?:\s|$)/

  defp parse(output) do
    with line when is_binary(line) <- last_line(output),
         [_blocks, _used, available] <- Regex.run(@data_row, line, capture: :all_but_first) do
      {:ok, max(String.to_integer(available), 0) * 1024}
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
