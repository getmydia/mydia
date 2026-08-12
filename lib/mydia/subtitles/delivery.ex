defmodule Mydia.Subtitles.Delivery do
  @moduledoc """
  Produces subtitle content for a track in a requested format.

  External sidecars are read from disk and converted. Embedded text tracks are
  extracted with ffmpeg and cached, because extracting from a large remux takes
  seconds and the player would otherwise wait on every selection. Image tracks
  are refused: they play fine in direct mode, where the client renders them from
  the container itself, but they cannot become text.

  The cache lives under the system temp directory. That needs no new
  configuration, and losing it on reboot costs one re-extraction. `MYDIA_DATA_DIR`
  is not the right home despite the name: it sits under `config :mydia,
  :direct_urls` and is scoped to certificate storage.
  """

  require Logger

  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Subtitles.Format
  alias Mydia.Subtitles.Subtitle

  @cache_root "mydia-subtitles"
  @extract_timeout 60_000

  @doc """
  Returns the root of the extracted-subtitle cache.
  """
  @spec cache_dir() :: String.t()
  def cache_dir, do: Path.join(System.tmp_dir!(), @cache_root)

  @doc """
  Returns subtitle content for a track, converted to `format`.

  `track_id` is a UUID string for an external sidecar, an integer for an
  embedded track, or `{:image, index}` for an embedded bitmap track.
  """
  @spec content(MediaFile.t(), integer() | String.t() | {:image, integer()}, String.t()) ::
          {:ok, binary()} | {:error, term()}
  def content(media_file, track_id, format)

  def content(_media_file, {:image, _index}, _format), do: {:error, :image_subtitle}

  def content(media_file, track_id, format) when is_binary(track_id) do
    with {:ok, subtitle} <- fetch_subtitle(media_file, track_id),
         {:ok, raw} <- read_file(subtitle.file_path) do
      Format.convert(raw, subtitle.format, format)
    end
  end

  def content(media_file, track_id, format) when is_integer(track_id) do
    with {:ok, path} <- absolute_path(media_file),
         {:ok, stat} <- File.stat(path) do
      cached = cache_path(media_file.id, track_id, stat, format)

      case File.read(cached) do
        {:ok, content} ->
          {:ok, content}

        {:error, _} ->
          with {:ok, content} <- extract(path, track_id, format) do
            write_cache(cached, content)
            {:ok, content}
          end
      end
    end
  end

  ## Private

  defp fetch_subtitle(media_file, track_id) do
    case Repo.get(Subtitle, track_id) do
      nil -> {:error, :subtitle_not_found}
      %Subtitle{media_file_id: id} = subtitle when id == media_file.id -> {:ok, subtitle}
      _other -> {:error, :unauthorized}
    end
  rescue
    Ecto.Query.CastError -> {:error, :subtitle_not_found}
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp absolute_path(media_file) do
    case MediaFile.absolute_path(media_file) do
      nil -> {:error, :media_file_not_found}
      path -> if File.exists?(path), do: {:ok, path}, else: {:error, :media_file_not_found}
    end
  end

  defp cache_path(media_file_id, track_id, %File.Stat{mtime: mtime, size: size}, format) do
    stamp = :erlang.phash2({mtime, size})
    Path.join([cache_dir(), media_file_id, "#{track_id}-#{stamp}.#{format}"])
  end

  defp write_cache(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  rescue
    e ->
      Logger.warning("Failed to cache extracted subtitle: #{inspect(e)}")
      :ok
  end

  defp extract(media_path, track_id, format) do
    out =
      Path.join(
        System.tmp_dir!(),
        "mydia-subextract-#{:erlang.unique_integer([:positive])}.#{format}"
      )

    args = ["-v", "error", "-y", "-i", media_path, "-map", "0:#{track_id}", out]

    try do
      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_output, 0} -> read_file(out)
        {output, _code} -> {:error, {:extraction_failed, String.slice(output, 0, 500)}}
      end
    rescue
      _e in ErlangError -> {:error, :ffmpeg_not_found}
    after
      File.rm(out)
    end
  end

  # Silence an unused-attribute warning if the timeout is not wired to System.cmd.
  _ = @extract_timeout
end
