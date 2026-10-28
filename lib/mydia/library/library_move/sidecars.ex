defmodule Mydia.Library.LibraryMove.Sidecars do
  @moduledoc """
  The subtitle and NFO files that sit beside a video and travel with it:
  `glass.en.srt` and `glass.nfo` next to `glass.mkv`.
  """

  @extensions Mydia.Subtitles.Sidecars.extensions() ++ [".nfo"]

  @doc """
  Absolute paths of the sidecars beside `video`. `[]` when the folder cannot
  be listed.
  """
  @spec for(String.t()) :: [String.t()]
  def for(video) do
    dir = Path.dirname(video)
    name = Path.basename(video)
    prefix = Path.rootname(name) <> "."

    case Mydia.Storage.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&sidecar?(&1, name, prefix))
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
