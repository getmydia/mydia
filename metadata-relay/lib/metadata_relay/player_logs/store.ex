defmodule MetadataRelay.PlayerLogs.Store do
  @moduledoc """
  The player log files under `player_logs.dir`.

  Paths handed in and out are relative to that directory. Every segment of
  one comes from a validated UUID, a validated report code, a date or an
  integer, so none can climb out of it.

  A file is written to `<name>.tmp` and renamed into place, so a reader never
  sees half of one.
  """

  alias MetadataRelay.PlayerLogs.Meta

  @spec root() :: Path.t()
  def root, do: Application.fetch_env!(:metadata_relay, :player_logs) |> Keyword.fetch!(:dir)

  @spec stream_path(String.t(), Date.t(), integer()) :: Path.t()
  def stream_path(device_id, %Date{} = date, first_t) do
    Path.join(["stream", device_id, Date.to_iso8601(date), "#{first_t}-#{rand()}.ndjson.gz"])
  end

  @spec report_path(String.t(), integer()) :: Path.t()
  def report_path(code, first_t),
    do: Path.join(["reports", code, "#{first_t}-#{rand()}.ndjson.gz"])

  @doc "Gzips `lines` into `relative`. Returns the compressed size."
  @spec write(Path.t(), iodata()) :: {:ok, non_neg_integer()} | {:error, term()}
  def write(relative, lines) do
    final = absolute(relative)
    tmp = final <> ".tmp"
    gz = :zlib.gzip(lines)

    with :ok <- File.mkdir_p(Path.dirname(final)),
         :ok <- File.write(tmp, gz),
         :ok <- File.rename(tmp, final) do
      {:ok, byte_size(gz)}
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @doc "The file's lines, lazily, each ending in a newline."
  @spec stream_lines(Path.t()) :: Enumerable.t()
  def stream_lines(relative), do: relative |> absolute() |> File.stream!([:compressed])

  @spec delete(Path.t()) :: :ok
  def delete(relative) do
    _ = File.rm(absolute(relative))
    :ok
  end

  @doc """
  Every log file and leftover `.tmp` last modified before `cutoff` (POSIX
  seconds), relative to the root.
  """
  @spec files_older_than(integer()) :: [Path.t()]
  def files_older_than(cutoff) do
    root = root()

    root
    |> Path.join("**/*.{gz,tmp}")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      match?({:ok, %File.Stat{mtime: mtime}} when mtime < cutoff, File.stat(path, time: :posix))
    end)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  @doc false
  @spec meta_path(Meta.t(), String.t() | nil, Date.t(), integer()) :: Path.t()
  def meta_path(%Meta{} = meta, nil, date, first_t),
    do: stream_path(meta.device_id, date, first_t)

  def meta_path(%Meta{}, code, _date, first_t), do: report_path(code, first_t)

  defp absolute(relative), do: Path.join(root(), relative)

  defp rand, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
end
