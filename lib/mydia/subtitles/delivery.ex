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
  alias Mydia.Subtitles.Offset
  alias Mydia.Subtitles.Subtitle
  alias Mydia.Subtitles.TrackSettings

  @cache_root "mydia-subtitles"
  @extract_timeout 60_000

  # Resolved at compile time so the guard below stays a guard while
  # `Subtitle.supported_formats/0` remains the single source of truth.
  @supported_formats Subtitle.supported_formats()

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

  # `format` reaches a cache path and an ffmpeg argument, and the REST
  # controller reads it as a free-form query parameter rather than through the
  # GraphQL enum. Without this an unsupported value walks straight into
  # `cache_path/5`, so `?format=../../x` writes outside the cache directory.
  # `Subtitle.supported_formats/0` is the single source of truth.
  def content(_media_file, _track_id, format)
      when format not in @supported_formats,
      do: {:error, {:unsupported_format, format}}

  def content(_media_file, {:image, _index}, _format), do: {:error, :image_subtitle}

  def content(media_file, track_id, format) when is_binary(track_id) do
    with {:ok, subtitle} <- fetch_subtitle(media_file, track_id),
         {:ok, raw} <- read_file(subtitle.file_path),
         {:ok, converted} <- Format.convert(raw, subtitle.format, format) do
      {:ok, apply_offset(converted, format, media_file.id, track_id)}
    end
  end

  def content(media_file, track_id, format) when is_integer(track_id) do
    offset_ms = TrackSettings.offset_ms(media_file.id, to_string(track_id))

    with {:ok, path} <- absolute_path(media_file),
         {:ok, stat} <- File.stat(path) do
      # The offset joins the cache key. Without it, changing an offset serves
      # the body cached from before the change and the feature looks inert.
      cached = cache_path(media_file.id, track_id, stat, format, offset_ms)

      case File.read(cached) do
        {:ok, content} ->
          {:ok, content}

        {:error, _} ->
          with {:ok, content} <- extract(path, track_id, format) do
            shifted = Offset.shift(content, format, offset_ms)
            write_cache(cached, shifted)
            {:ok, shifted}
          end
      end
    end
  end

  @doc false
  # Public with @doc false rather than private: the offset joining this key is
  # the guard against serving a stale body after an offset changes, and it is
  # the one part of that path a test can reach without a real media file on
  # disk and a working ffmpeg. Not part of the module's contract.
  @spec cache_path(binary(), integer(), File.Stat.t(), String.t(), integer()) :: String.t()
  def cache_path(media_file_id, track_id, %File.Stat{mtime: mtime, size: size}, format, offset_ms) do
    stamp = :erlang.phash2({mtime, size, offset_ms})
    Path.join([cache_dir(), media_file_id, "#{track_id}-#{stamp}.#{format}"])
  end

  @doc """
  Converts a stored `track_ref` into the shape `content/3` dispatches on.

  An embedded track's ref is a stringified ffprobe stream index and must arrive
  as an integer; a sidecar's ref is a UUID and must stay a binary. `content/3`
  distinguishes the two by type alone, so a caller holding a `track_ref` from
  `subtitle_track_settings` has to translate first.
  """
  @spec track_id_from_ref(String.t()) :: String.t() | integer()
  def track_id_from_ref(track_ref) when is_binary(track_ref) do
    case Integer.parse(track_ref) do
      {index, ""} -> index
      _ -> track_ref
    end
  end

  ## Private

  # `track_ref` is the string form for both kinds of track, matching what
  # `Mydia.Subtitles.TrackSetting` stores and what the GraphQL wire carries.
  defp apply_offset(content, format, media_file_id, track_ref) do
    Offset.shift(content, format, TrackSettings.offset_ms(media_file_id, to_string(track_ref)))
  end

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
