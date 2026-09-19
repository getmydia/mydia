defmodule Mydia.Subtitles.ImageTrack do
  @moduledoc """
  An embedded bitmap subtitle track (PGS, VobSub, DVB, XSUB), copied out of
  its container into a subtitle-only Matroska file that the player's mpv
  loads beside an HLS stream.

  `Mydia.Subtitles.Delivery` refuses bitmap tracks because they cannot
  become text. They do not need to: mpv draws them itself once handed the
  track. Stream-copying one track costs almost no CPU, but ffmpeg still
  demuxes the whole source to find that track's packets, and on a 20 GB
  remux that outlasts every deadline between the player and this server.
  So the first request starts the copy in the background and answers
  `:pending`, and the player polls until the file exists.

  The file lives in `Delivery`'s cache under the key text uses (media file
  id, stream index, and a stamp of the source's mtime and size), so every
  session shares one copy and a replaced source gets a fresh one.

  A failed copy leaves a `.failed` marker beside the cache path, and
  `path/2` reports the failure while the marker stands. Without it every
  poll would start another full read of a file that already failed once.
  The marker carries the same stamp, so a replaced source is tried again.

  A bitmap track runs to tens of MB where a text track runs to KB, and
  nothing else evicts the cache. Serving a file touches it, and every new
  copy first removes files nobody has touched for seven days.
  """

  require Logger

  alias Mydia.Library.MediaFile
  alias Mydia.Plugins.SingleFlight
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.Extractor
  alias Mydia.Subtitles.Format

  @format "mks"
  @lock Mydia.Streaming.SubtitleLock
  @stale_after_seconds 7 * 24 * 60 * 60

  @type error ::
          :not_image_track | :subtitle_not_found | :media_file_not_found | :extraction_failed

  @doc """
  The cached copy of embedded bitmap stream `index` of `media_file`, or
  `:pending` while it is being copied out of the source.

  `media_file` must have its `library_path` preloaded.
  """
  @spec path(MediaFile.t(), non_neg_integer()) ::
          {:ok, String.t()} | :pending | {:error, error()}
  def path(%MediaFile{} = media_file, index) when is_integer(index) do
    with {:ok, source, cached} <- locate(media_file, index) do
      cond do
        File.exists?(cached) ->
          File.touch(cached)
          {:ok, cached}

        File.exists?(failed_marker(cached)) ->
          {:error, :extraction_failed}

        true ->
          start_copy(source, index, cached)
          :pending
      end
    end
  end

  @doc false
  # Where `path/2` keeps this track's copy, whether or not it exists yet.
  # Public so tests can pre-warm or poison the cache without ffmpeg.
  @spec cache_path(MediaFile.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, error()}
  def cache_path(media_file, index) do
    with {:ok, _source, cached} <- locate(media_file, index), do: {:ok, cached}
  end

  @doc false
  @spec failed_marker(String.t()) :: String.t()
  def failed_marker(cached), do: cached <> ".failed"

  @doc false
  # The lock one copy holds. Public so a test can hold it and observe
  # `:pending` without running ffmpeg.
  @spec lock_slug(String.t()) :: String.t()
  def lock_slug(cached), do: "image_track:" <> cached

  @doc false
  # Removes copies, failure markers and abandoned temp files nobody has
  # touched for seven days before `now` (posix seconds). Public for its
  # test, which cannot wait a week.
  @spec evict_stale(integer()) :: :ok
  def evict_stale(now) when is_integer(now) do
    cutoff = now - @stale_after_seconds
    root = Delivery.cache_dir()

    ["*.mks", "*.failed", "*.mks.tmp-*"]
    |> Enum.flat_map(&Path.wildcard(Path.join([root, "*", &1])))
    |> Enum.each(&remove_if_older(&1, cutoff))
  end

  defp remove_if_older(file, cutoff) do
    case File.stat(file, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} when mtime < cutoff -> File.rm(file)
      _ -> :ok
    end
  end

  defp locate(media_file, index) do
    with :ok <- check_image_track(media_file, index),
         {:ok, source, stat} <- source(media_file) do
      {:ok, source, Delivery.cache_path(media_file.id, index, stat, @format, 0)}
    end
  end

  defp check_image_track(media_file, index) do
    media_file
    |> Extractor.list_subtitle_tracks()
    |> Enum.find(&(&1.embedded and &1.track_id == index))
    |> case do
      nil -> {:error, :subtitle_not_found}
      track -> if Format.image_format?(track.format), do: :ok, else: {:error, :not_image_track}
    end
  end

  defp source(media_file) do
    with path when is_binary(path) <- MediaFile.absolute_path(media_file),
         {:ok, stat} <- File.stat(path) do
      {:ok, path, stat}
    else
      _ -> {:error, :media_file_not_found}
    end
  end

  # Under `Mydia.TaskSupervisor`, so the copy outlives the request that
  # started it. Every poll that finds no file starts a task too; while a
  # copy holds the lock those tasks get `{:busy}` and exit at once.
  defp start_copy(source, index, cached) do
    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      SingleFlight.run(
        lock_slug(cached),
        :skip,
        fn -> copy_once(source, index, cached) end,
        @lock
      )
    end)
  end

  # Re-checked under the lock: the copy that held it before may have just
  # finished, or just failed.
  defp copy_once(source, index, cached) do
    if File.exists?(cached) or File.exists?(failed_marker(cached)) do
      :ok
    else
      evict_stale(System.os_time(:second))
      copy(source, index, cached)
    end
  end

  defp copy(source, index, cached) do
    File.mkdir_p!(Path.dirname(cached))
    # A unique temp name in the same directory, renamed into place, so
    # `path/2` never serves a half-written file.
    tmp = "#{cached}.tmp-#{System.unique_integer([:positive])}"

    args = [
      "-v",
      "error",
      "-y",
      "-i",
      source,
      "-map",
      "0:#{index}",
      "-c",
      "copy",
      "-f",
      "matroska",
      tmp
    ]

    case run_ffmpeg(args) do
      :ok ->
        File.rename!(tmp, cached)

      {:error, output} ->
        File.rm(tmp)
        reason = String.slice(output, 0, 500)
        Logger.warning("Image subtitle copy failed", path: cached, reason: reason)
        File.write!(failed_marker(cached), reason)
    end
  end

  defp run_ffmpeg(args) do
    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, output}
    end
  rescue
    ErlangError -> {:error, "ffmpeg not found"}
  end
end
