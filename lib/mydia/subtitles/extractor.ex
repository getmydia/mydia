defmodule Mydia.Subtitles.Extractor do
  @moduledoc """
  Extracts subtitle tracks from media files using FFprobe and FFmpeg.

  Provides functionality to:
  - List all subtitle streams (embedded and external)
  - Extract embedded subtitle tracks to temporary files
  - Convert between subtitle formats (SRT, VTT, ASS)
  """

  require Logger

  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Subtitles.Format

  @doc """
  Lists all available subtitle tracks for a media file.

  Returns both embedded subtitles (from the media file) and external subtitle files
  (from the Subtitles context).

  ## Parameters

  - `media_file` - MediaFile struct with library_path preloaded
  - `opts` - Keyword list of options

  ## Returns

  List of subtitle track maps with:
  - `track_id` - Unique identifier (integer for embedded, subtitle_id for external)
  - `language` - ISO 639-2 language code
  - `title` - Display title
  - `format` - Subtitle format (srt, vtt, ass, subrip, etc.)
  - `embedded` - Boolean indicating if subtitle is embedded in media file
  - `deliverable` - Boolean indicating if the track can be served as text
    (false for image-based formats like pgs/vobsub)

  Embedded tracks are read from `media_file.metadata.streams` when present,
  falling back to ffprobe only when the file has never been analyzed.

  ## Examples

      iex> list_subtitle_tracks(media_file)
      [
        %{track_id: 0, language: "eng", title: "English", format: "subrip", embedded: true, deliverable: true},
        %{track_id: 1, language: "spa", title: "Spanish", format: "ass", embedded: true, deliverable: true},
        %{track_id: "sub-123", language: "en", title: "English (External)", format: "srt", embedded: false, deliverable: true}
      ]
  """
  def list_subtitle_tracks(media_file, _opts \\ []) do
    embedded_tracks = embedded_tracks(media_file)
    external_tracks = get_external_subtitles(media_file.id)

    embedded_tracks ++ external_tracks
  end

  # Prefer the stored stream capture. ffprobe on every GraphQL query is a hot
  # path the player hits for every file in a list.
  defp embedded_tracks(%{metadata: %FileMetadata{streams: streams}}) when is_list(streams) do
    streams
    |> Enum.filter(&(&1.type == :subtitle))
    |> Enum.map(&build_embedded_track_from_stream/1)
  end

  defp embedded_tracks(media_file), do: embedded_tracks_via_ffprobe(media_file)

  defp embedded_tracks_via_ffprobe(media_file) do
    absolute_path = Mydia.Library.MediaFile.absolute_path(media_file)

    if absolute_path && File.exists?(absolute_path) do
      case get_embedded_subtitles(absolute_path) do
        {:ok, tracks} -> tracks
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  defp build_embedded_track_from_stream(%{index: index, codec: codec} = stream) do
    language = stream.language || "und"
    format = normalize_subtitle_format(codec)

    %{
      track_id: index,
      language: language,
      title: stream.title || format_language_name(language),
      format: format,
      embedded: true,
      deliverable: not Format.image_format?(format)
    }
  end

  @doc """
  Extracts a specific subtitle track from a media file.

  For embedded subtitles, extracts the track to a temporary file and returns the path.
  For external subtitles, returns the existing file path.

  ## Parameters

  - `media_file` - MediaFile struct with library_path preloaded
  - `track_id` - Track identifier (integer for embedded, binary for external)
  - `opts` - Keyword list of options:
    - `:format` - Output format (default: "srt")

  ## Returns

  - `{:ok, file_path}` - Path to the subtitle file
  - `{:error, reason}` - Error tuple

  ## Examples

      iex> extract_subtitle_track(media_file, 0)
      {:ok, "/tmp/subtitle-track-0.srt"}

      iex> extract_subtitle_track(media_file, "sub-123")
      {:ok, "/path/to/external/subtitle.srt"}
  """
  def extract_subtitle_track(media_file, track_id, opts \\ [])

  # External subtitle - return the file path
  def extract_subtitle_track(media_file, track_id, _opts) when is_binary(track_id) do
    case Mydia.Repo.get(Mydia.Subtitles.Subtitle, track_id) do
      nil ->
        {:error, :subtitle_not_found}

      subtitle ->
        if subtitle.media_file_id == media_file.id do
          if File.exists?(subtitle.file_path) do
            {:ok, subtitle.file_path}
          else
            {:error, :file_not_found}
          end
        else
          {:error, :unauthorized}
        end
    end
  end

  # Embedded subtitle - extract to temporary file
  def extract_subtitle_track(media_file, track_id, opts) when is_integer(track_id) do
    absolute_path = Mydia.Library.MediaFile.absolute_path(media_file)

    if absolute_path && File.exists?(absolute_path) do
      output_format = Keyword.get(opts, :format, "srt")
      extract_embedded_subtitle(absolute_path, track_id, output_format)
    else
      {:error, :media_file_not_found}
    end
  end

  ## Private Functions

  # Get embedded subtitle tracks from media file using FFprobe
  defp get_embedded_subtitles(file_path) do
    args = [
      "-v",
      "quiet",
      "-print_format",
      "json",
      "-show_streams",
      "-select_streams",
      "s",
      file_path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"streams" => streams}} ->
            tracks =
              streams
              |> Enum.with_index()
              |> Enum.map(fn {stream, _index} ->
                build_embedded_track(stream)
              end)

            {:ok, tracks}

          {:error, _error} ->
            {:error, :invalid_json}
        end

      {_error_output, _exit_code} ->
        {:error, :ffprobe_failed}
    end
  rescue
    _e in ErlangError ->
      {:error, :ffprobe_not_found}
  end

  # Build embedded subtitle track map from FFprobe stream data
  defp build_embedded_track(stream) do
    track_index = stream["index"]
    codec_name = stream["codec_name"]

    # Extract language from tags
    tags = stream["tags"] || %{}
    language = tags["language"] || "und"
    title = tags["title"] || format_language_name(language)

    %{
      track_id: track_index,
      language: language,
      title: title,
      format: normalize_subtitle_format(codec_name),
      embedded: true,
      deliverable: not Format.image_format?(normalize_subtitle_format(codec_name))
    }
  end

  # Normalize subtitle codec names to standard format names
  defp normalize_subtitle_format("subrip"), do: "srt"
  defp normalize_subtitle_format("ass"), do: "ass"
  defp normalize_subtitle_format("ssa"), do: "ass"
  defp normalize_subtitle_format("webvtt"), do: "vtt"
  defp normalize_subtitle_format("mov_text"), do: "srt"
  defp normalize_subtitle_format("dvd_subtitle"), do: "vobsub"
  defp normalize_subtitle_format("hdmv_pgs_subtitle"), do: "pgs"
  defp normalize_subtitle_format(codec), do: codec || "unknown"

  @doc """
  Subtitle tracks stored as sidecar files for a media file.

  Reads only the database. Unlike `list_subtitle_tracks/2` this never runs
  ffprobe, which makes it safe to resolve on a hot GraphQL path.
  """
  def list_external_subtitle_tracks(media_file_id) do
    Mydia.Subtitles.list_subtitles(media_file_id)
    |> Enum.map(fn subtitle ->
      %{
        track_id: subtitle.id,
        language: subtitle.language,
        title: format_external_title(subtitle),
        format: subtitle.format,
        embedded: false,
        deliverable: true
      }
    end)
  end

  defp get_external_subtitles(media_file_id), do: list_external_subtitle_tracks(media_file_id)

  # Format external subtitle title
  defp format_external_title(subtitle) do
    lang_name = format_language_name(subtitle.language)
    "#{lang_name} (External)"
  end

  # Format language code to display name (basic implementation)
  defp format_language_name("eng"), do: "English"
  defp format_language_name("en"), do: "English"
  defp format_language_name("spa"), do: "Spanish"
  defp format_language_name("es"), do: "Spanish"
  defp format_language_name("fra"), do: "French"
  defp format_language_name("fr"), do: "French"
  defp format_language_name("deu"), do: "German"
  defp format_language_name("de"), do: "German"
  defp format_language_name("ita"), do: "Italian"
  defp format_language_name("it"), do: "Italian"
  defp format_language_name("por"), do: "Portuguese"
  defp format_language_name("pt"), do: "Portuguese"
  defp format_language_name("jpn"), do: "Japanese"
  defp format_language_name("ja"), do: "Japanese"
  defp format_language_name("kor"), do: "Korean"
  defp format_language_name("ko"), do: "Korean"
  defp format_language_name("chi"), do: "Chinese"
  defp format_language_name("zh"), do: "Chinese"
  defp format_language_name("rus"), do: "Russian"
  defp format_language_name("ru"), do: "Russian"
  defp format_language_name("ara"), do: "Arabic"
  defp format_language_name("ar"), do: "Arabic"
  defp format_language_name("und"), do: "Unknown"
  defp format_language_name(code), do: String.upcase(code)

  # Extract embedded subtitle to temporary file using FFmpeg
  defp extract_embedded_subtitle(file_path, track_id, output_format) do
    # Create temporary file for subtitle
    temp_file =
      Path.join(
        System.tmp_dir!(),
        "mydia-subtitle-#{track_id}-#{:rand.uniform(999_999)}.#{output_format}"
      )

    args = [
      "-v",
      "quiet",
      "-i",
      file_path,
      "-map",
      "0:#{track_id}",
      "-f",
      output_format,
      temp_file
    ]

    Logger.debug("Extracting subtitle track #{track_id} from #{file_path}")

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(temp_file) do
          {:ok, temp_file}
        else
          {:error, :extraction_failed}
        end

      {error_output, exit_code} ->
        Logger.error("FFmpeg subtitle extraction failed",
          exit_code: exit_code,
          output: error_output,
          track_id: track_id
        )

        {:error, :ffmpeg_failed}
    end
  rescue
    _e in ErlangError ->
      {:error, :ffmpeg_not_found}
  end
end
