defmodule Mydia.Library.LibraryMove.Sidecars do
  @moduledoc """
  The subtitle and NFO files that sit beside a video and travel with it:
  `glass.en.srt` and `glass.nfo` next to `glass.mkv`.
  """

  alias Mydia.Library.MediaFile

  @extensions Mydia.Subtitles.Sidecars.extensions() ++ [".nfo"]

  @doc """
  Absolute paths of the sidecars that belong to `media_file` where it sits
  (or sat: an unsaved struct for an old location works too), with
  `:library_path` loaded. A name that starts with the video's also has to be
  owned by it under `Mydia.Subtitles.Sidecars.owned_by/2`, so `Glass.mkv`
  never takes `Glass.Harbor.en.srt` from `Glass.Harbor.mkv` beside it.
  Compute this before the row moves: afterwards the file is no longer among
  the folder's siblings. `[]` when the folder cannot be listed.
  """
  @spec for(MediaFile.t()) :: [String.t()]
  def for(%MediaFile{} = media_file) do
    case MediaFile.storage_path(media_file) do
      nil -> []
      video -> list(media_file, video)
    end
  end

  defp list(media_file, video) do
    dir = Path.dirname(video)
    name = Path.basename(video)
    prefix = Path.rootname(name) <> "."

    case Mydia.Storage.ls(dir) do
      {:ok, entries} ->
        candidates = Enum.filter(entries, &sidecar?(&1, name, prefix))

        media_file
        |> Mydia.Subtitles.Sidecars.owned_by(candidates)
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp sidecar?(entry, name, prefix) do
    entry != name and String.starts_with?(entry, prefix) and
      String.downcase(Path.extname(entry)) in @extensions
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
end
