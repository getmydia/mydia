defmodule Mydia.Streaming.Compatibility do
  @moduledoc """
  Determines browser compatibility for media files to decide between
  direct play, fMP4 remuxing, and HLS transcoding.

  Browser compatibility is based on modern web standards (Chrome, Firefox, Safari, Edge).

  ## Streaming modes

  - `:direct_play` - Browser can handle the file natively (compatible container + codecs)
  - `:needs_remux` - Codecs are browser-compatible but container isn't (e.g., MKV with H.264/AAC).
    Can be remuxed to fMP4 on-the-fly without transcoding.
  - `:needs_transcoding` - Codecs are not browser-compatible, requires full transcoding
  """

  alias Mydia.Library.MediaFile

  @type streaming_mode :: :direct_play | :needs_remux | :needs_transcoding

  @doc """
  Checks if a media file can be played directly in the browser, needs remuxing, or needs transcoding.

  Returns:
  - `:direct_play` - Browser can handle the file natively (compatible container + codecs)
  - `:needs_remux` - Codecs are compatible but container isn't (e.g., MKV with H.264/AAC)
  - `:needs_transcoding` - Codecs are incompatible, requires full transcoding

  ## Examples

      iex> media_file = %MediaFile{codec: "h264", audio_codec: "aac", metadata: %Mydia.Library.Structs.FileMetadata{container: "mp4"}}
      iex> check_compatibility(media_file)
      :direct_play

      iex> media_file = %MediaFile{codec: "h264", audio_codec: "aac", metadata: %Mydia.Library.Structs.FileMetadata{container: "mkv"}}
      iex> check_compatibility(media_file)
      :needs_remux

      iex> media_file = %MediaFile{codec: "hevc", audio_codec: "aac", metadata: %Mydia.Library.Structs.FileMetadata{container: "mkv"}}
      iex> check_compatibility(media_file)
      :needs_transcoding
  """
  @spec check_compatibility(MediaFile.t()) :: streaming_mode()
  def check_compatibility(%MediaFile{} = media_file) do
    container = get_container_format(media_file)
    video_codec = media_file.codec
    audio_codec = media_file.audio_codec

    cond do
      browser_compatible?(container, video_codec, audio_codec) ->
        :direct_play

      remux_eligible?(container, video_codec, audio_codec) ->
        :needs_remux

      true ->
        :needs_transcoding
    end
  end

  # Determines if the given combination of container, video codec, and audio codec
  # is compatible with modern browsers.
  # Note: Videos without audio (nil audio_codec) are allowed if video is compatible.
  defp browser_compatible?(container, video_codec, audio_codec) do
    compatible_container?(container) and
      compatible_video_codec?(video_codec) and
      audio_compatible_or_absent?(audio_codec)
  end

  # Determines if a file can be remuxed to fMP4 without transcoding.
  # This is possible when the codecs are browser-compatible but the container isn't.
  # Note: Videos without audio (nil audio_codec) are allowed if video is compatible.
  defp remux_eligible?(container, video_codec, audio_codec) do
    remuxable_container?(container) and
      compatible_video_codec?(video_codec) and
      audio_compatible_or_absent?(audio_codec)
  end

  # Audio is considered compatible if it's a known compatible codec or if there's no audio track
  defp audio_compatible_or_absent?(nil), do: true
  defp audio_compatible_or_absent?(audio_codec), do: compatible_audio_codec?(audio_codec)

  # Containers that browsers can play directly
  defp compatible_container?(nil), do: false

  defp compatible_container?(container) do
    normalized = String.downcase(container)

    normalized in [
      "mp4",
      "webm",
      # Browser may handle these via video element
      "m4v"
    ]
  end

  # Containers that can be remuxed to fMP4 without transcoding.
  # These containers support the same codecs as MP4 but browsers can't play them directly.
  defp remuxable_container?(nil), do: false

  defp remuxable_container?(container) do
    normalized = String.downcase(container)

    normalized in [
      "mkv",
      "matroska",
      "avi",
      "mov",
      "ts",
      "mpegts",
      "m2ts",
      "mts",
      "wmv",
      "flv"
    ]
  end

  # Video codecs that browsers support natively
  defp compatible_video_codec?(nil), do: false

  defp compatible_video_codec?(codec) do
    normalized = String.downcase(codec)

    # Check for compatible codecs - handle formatted strings like "H.264 (Main)" or "HEVC"
    cond do
      # H.264 / AVC - browser compatible
      String.contains?(normalized, "h264") or
        String.contains?(normalized, "h.264") or
          normalized in ["avc", "avc1"] ->
        true

      # VP9 - browser compatible
      String.contains?(normalized, "vp9") or normalized == "vp09" ->
        true

      # AV1 - browser compatible
      String.contains?(normalized, "av1") or normalized == "av01" ->
        true

      # HEVC/H.265 - NOT browser compatible (needs transcoding)
      String.contains?(normalized, "hevc") or String.contains?(normalized, "h.265") or
          String.contains?(normalized, "h265") ->
        false

      # Everything else - not compatible
      true ->
        false
    end
  end

  @doc """
  Whether a browser can decode this audio codec natively.

  Public because the remuxer has to ask it about the *specific* stream it
  maps, not about `media_file.audio_codec`. That column describes the first
  audio stream, which is what chose the REMUX strategy in the first place; if
  language selection then maps a different stream, `-c copy` would put a codec
  in the fMP4 that the client's `canPlayType` check never approved and the
  advertised MIME no longer describes.
  """
  @spec compatible_audio_codec?(String.t() | nil) :: boolean()
  def compatible_audio_codec?(nil), do: false

  def compatible_audio_codec?(codec) do
    normalized = String.downcase(codec)

    # Check for compatible codecs - handle formatted strings like "AAC 5.1" or "MP3 Stereo"
    String.contains?(normalized, "aac") or
      String.contains?(normalized, "mp3") or
      String.contains?(normalized, "opus") or
      String.contains?(normalized, "vorbis")
  end

  @doc """
  Extracts the container format from a media file.

  Tries in order:
  1. `metadata["container"]`
  2. `metadata["format_name"]` (first value if comma-separated)
  3. File extension from absolute path

  Returns "unknown" if none can be determined.
  """
  @spec get_container_format(MediaFile.t()) :: String.t()
  def get_container_format(%MediaFile{metadata: metadata} = media_file) do
    # First try to get from metadata
    case metadata do
      %{container: container} when is_binary(container) ->
        container

      %{format_name: format_name} when is_binary(format_name) ->
        # FFprobe may return comma-separated formats like "mov,mp4,m4a"
        # Take the first one
        format_name
        |> String.split(",")
        |> List.first()
        |> String.trim()

      _ ->
        # Fall back to file extension from absolute path
        case MediaFile.absolute_path(media_file) do
          nil ->
            "unknown"

          absolute_path ->
            absolute_path
            |> Path.extname()
            |> String.trim_leading(".")
            |> String.downcase()
        end
    end
  end

  @doc """
  Returns a human-readable description of why the file cannot be played directly.

  This describes the first incompatibility found (container, video codec, or audio codec).

  ## Examples

      iex> media_file = %MediaFile{codec: "hevc", audio_codec: "aac", metadata: %{"container" => "mkv"}}
      iex> transcoding_reason(media_file)
      "Incompatible video codec (hevc)"

      iex> media_file = %MediaFile{codec: "h264", audio_codec: "aac", metadata: %{"container" => "mkv"}}
      iex> transcoding_reason(media_file)
      "Incompatible container format (mkv)"
  """
  @spec transcoding_reason(MediaFile.t()) :: String.t()
  def transcoding_reason(%MediaFile{} = media_file) do
    container = get_container_format(media_file)
    video_codec = media_file.codec
    audio_codec = media_file.audio_codec

    cond do
      not compatible_video_codec?(video_codec) ->
        "Incompatible video codec (#{video_codec || "unknown"})"

      not audio_compatible_or_absent?(audio_codec) ->
        "Incompatible audio codec (#{audio_codec || "unknown"})"

      not compatible_container?(container) ->
        "Incompatible container format (#{container || "unknown"})"

      true ->
        "Unknown compatibility issue"
    end
  end

  @doc """
  Returns a human-readable description of why a file needs remuxing.

  ## Examples

      iex> media_file = %MediaFile{codec: "h264", audio_codec: "aac", metadata: %{"container" => "mkv"}}
      iex> remux_reason(media_file)
      "Container (mkv) requires remuxing to fMP4"
  """
  @spec remux_reason(MediaFile.t()) :: String.t()
  def remux_reason(%MediaFile{} = media_file) do
    container = get_container_format(media_file)
    "Container (#{container}) requires remuxing to fMP4"
  end

  @doc """
  Returns true if the file needs remuxing (can be stream-copied to fMP4).

  This is a convenience function for checking if `check_compatibility/1` returns `:needs_remux`.
  """
  @spec needs_remux?(MediaFile.t()) :: boolean()
  def needs_remux?(%MediaFile{} = media_file) do
    check_compatibility(media_file) == :needs_remux
  end
end
