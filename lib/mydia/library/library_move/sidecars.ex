defmodule Mydia.Library.LibraryMove.Sidecars do
  @moduledoc """
  The subtitle, NFO, EDL and thumbnail files that sit beside a video and
  travel with it: `glass.en.srt`, `glass.nfo`, `glass.edl` and `glass-thumb.jpg`
  next to `glass.mkv`. An `.edl` left behind would no longer match the video,
  and the next scan would drop its commercial breaks
  (`Mydia.Library.EdlSidecars`). A `-thumb.jpg` or `-thumb.png` is the
  thumbnail media servers write beside a video.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Mydia.Library.FileMove
  alias Mydia.Library.FileOrganizer
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Subtitles.Subtitle

  @extensions Mydia.Subtitles.Sidecars.extensions() ++ [".nfo", ".edl"]
  @thumb_extensions [".jpg", ".png"]

  @doc """
  Absolute paths of the sidecars that belong to `media_file` where it sits
  (or sat: an unsaved struct for an old location works too), with
  `:library_path` loaded. A name that starts with the video's also has to be
  owned by it under `Mydia.Subtitles.Sidecars.owned_by/2`, so `Glass.mkv`
  never takes `Glass.Harbor.en.srt` from `Glass.Harbor.mkv` beside it.
  Compute this before the row moves: afterwards the file is no longer among
  the folder's siblings. A folder that does not exist has none; any other
  listing failure is an error, so a move retries instead of leaving the
  sidecars behind.
  """
  @spec for(MediaFile.t()) :: {:ok, [String.t()]} | {:error, Mydia.Storage.Error.t()}
  def for(%MediaFile{} = media_file) do
    case MediaFile.storage_path(media_file) do
      nil -> {:ok, []}
      video -> list(media_file, video)
    end
  end

  defp list(media_file, video) do
    dir = Path.dirname(video)
    name = Path.basename(video)

    case Mydia.Storage.ls(dir) do
      {:ok, entries} ->
        candidates = Enum.filter(entries, &sidecar_name?(&1, name))

        {:ok,
         media_file
         |> Mydia.Subtitles.Sidecars.owned_by(candidates)
         |> Enum.map(&Path.join(dir, &1))}

      {:error, %Mydia.Storage.Error{kind: :not_found}} ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Whether `entry` is a sidecar form of the video file named `video_name`:
  `<root>.<anything><ext>` for a sidecar extension, or `<root>-thumb.jpg` /
  `<root>-thumb.png`. Name shape only; no ownership check.
  """
  @spec sidecar_name?(String.t(), String.t()) :: boolean()
  def sidecar_name?(entry, video_name) do
    root = Path.rootname(video_name)
    ext = String.downcase(Path.extname(entry))

    entry != video_name and
      ((String.starts_with?(entry, root <> ".") and ext in @extensions) or
         (ext in @thumb_extensions and
            String.downcase(Path.rootname(entry)) == String.downcase(root <> "-thumb")))
  end

  @doc """
  Whether `entry` has a sidecar shape whatever video it belongs to: a sidecar
  extension, `.nfo`, `.edl`, or a `-thumb.jpg` / `-thumb.png` name. The
  extension is compared case-insensitively.
  """
  @spec sidecar_form?(String.t()) :: boolean()
  def sidecar_form?(entry) do
    ext = String.downcase(Path.extname(entry))

    ext in @extensions or
      (ext in @thumb_extensions and
         String.ends_with?(String.downcase(Path.rootname(entry)), "-thumb"))
  end

  @doc """
  Where `sidecar` goes when `source_video` moves to `dest_video`: the video's
  name prefix is swapped for the destination's, so `glass.en.srt` beside
  `glass.mkv` becomes `Glass Harbor (2019).en.srt` beside
  `Glass Harbor (2019).mkv`.
  """
  @spec dest_for(String.t(), String.t(), String.t()) :: String.t()
  def dest_for(sidecar, source_video, dest_video) do
    old_root = Path.rootname(Path.basename(source_video))
    new_root = Path.rootname(Path.basename(dest_video))
    tail = String.replace_prefix(Path.basename(sidecar), old_root, "")
    Path.join(Path.dirname(dest_video), new_root <> tail)
  end

  @doc """
  Moves each of `sidecars` to its `dest_for/3` place, confined to
  `confine_root`, and points the matching `subtitles` rows of
  `media_file_id` at the new path. Returns the sidecars left at the source.

  Best effort: a sidecar that cannot move never fails its video. A row is
  rewritten before its file moves and put back when the file stays, so a
  crash in between leaves the row ahead of a file that is still listed at
  the source, and the retry's sweep moves that file to where the row
  already points. A row is never pointed at a file this move did not place.
  """
  @spec move_all([String.t()], String.t(), String.t(), binary(), String.t()) :: [String.t()]
  def move_all(sidecars, source_video, dest_video, media_file_id, confine_root) do
    Enum.reject(sidecars, fn sidecar ->
      move_one(sidecar, dest_for(sidecar, source_video, dest_video), media_file_id, confine_root)
    end)
  end

  defp move_one(sidecar, dest, media_file_id, confine_root) do
    if FileMove.exists?(dest) do
      Logger.warning("Library move left a sidecar behind: destination exists", sidecar: sidecar)
      false
    else
      rewrite_subtitle_rows(media_file_id, sidecar, dest)
      place_sidecar(sidecar, dest, media_file_id, confine_root)
    end
  end

  defp place_sidecar(sidecar, dest, media_file_id, confine_root) do
    case FileOrganizer.place_file(sidecar, dest,
           use_hardlinks: true,
           remove_source_after_hardlink: true,
           fallback: :move,
           confine_to: confine_root
         ) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("Sidecar move failed", sidecar: sidecar, reason: inspect(reason))
        rewrite_subtitle_rows(media_file_id, dest, sidecar)
        false
    end
  end

  defp rewrite_subtitle_rows(media_file_id, from_path, to_path) do
    from(s in Subtitle, where: s.media_file_id == ^media_file_id and s.file_path == ^from_path)
    |> Repo.update_all(set: [file_path: to_path])
  end
end
