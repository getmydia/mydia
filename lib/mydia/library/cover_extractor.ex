defmodule Mydia.Library.CoverExtractor do
  @moduledoc """
  Extracts embedded cover art from audio files using FFmpeg.
  """

  @doc """
  Extracts embedded cover art from the given audio file.
  Returns `{:ok, binary_content}` or `{:error, reason}`.
  """
  def extract(file_path) do
    # ffmpeg -i file -an -vcodec copy -f image2 pipe:1
    args = [
      "-i",
      file_path,
      "-an",
      "-vcodec",
      "copy",
      "-f",
      "image2",
      "pipe:1"
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: false) do
      {output, 0} ->
        if byte_size(output) > 0 do
          {:ok, output}
        else
          {:error, :no_cover_found}
        end

      {_output, exit_code} ->
        {:error, {:ffmpeg_failed, exit_code}}
    end
  rescue
    e -> {:error, e}
  end
end
