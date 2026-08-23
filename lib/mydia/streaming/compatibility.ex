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
  alias Mydia.Streaming.DeviceProfile

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
    check_compatibility(media_file, DeviceProfile.browser_default())
  end

  @doc """
  Checks compatibility against a specific client's declared capabilities.

  With a real profile `:needs_remux` means what it says. Before profiles it
  meant "the codecs are fine but browsers cannot open this container", which is
  only true for one kind of client.
  """
  @spec check_compatibility(MediaFile.t(), DeviceProfile.t()) :: streaming_mode()
  def check_compatibility(%MediaFile{} = media_file, %DeviceProfile{} = profile) do
    container = get_container_format(media_file)
    video_codec = media_file.codec
    audio_codec = media_file.audio_codec
    hdr_format = media_file.hdr_format

    cond do
      client_can_play?(profile, container, video_codec, audio_codec, hdr_format) ->
        :direct_play

      remux_eligible?(profile, container, video_codec, audio_codec, hdr_format) ->
        :needs_remux

      true ->
        :needs_transcoding
    end
  end

  # The client can open this container and decode every stream in it as-is.
  defp client_can_play?(profile, container, video_codec, audio_codec, hdr_format) do
    DeviceProfile.container_allowed?(profile, container) and
      codecs_playable?(profile, video_codec, audio_codec, hdr_format)
  end

  # The codecs are fine but the container is not, so ffmpeg can stream-copy into
  # fMP4 without re-encoding. `remuxable_container?/1` stays hardcoded because it
  # describes what ffmpeg can repackage, which is a server capability and does
  # not vary by client.
  defp remux_eligible?(profile, container, video_codec, audio_codec, hdr_format) do
    remuxable_container?(container) and
      codecs_playable?(profile, video_codec, audio_codec, hdr_format)
  end

  defp codecs_playable?(profile, video_codec, audio_codec, hdr_format) do
    DeviceProfile.video_codec_allowed?(profile, video_codec) and
      DeviceProfile.audio_codec_allowed_or_absent?(profile, audio_codec) and
      DeviceProfile.hdr_allowed_or_absent?(profile, hdr_format)
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
    profile = DeviceProfile.browser_default()
    container = get_container_format(media_file)
    video_codec = media_file.codec
    audio_codec = media_file.audio_codec

    cond do
      not DeviceProfile.video_codec_allowed?(profile, video_codec) ->
        "Incompatible video codec (#{video_codec || "unknown"})"

      not DeviceProfile.audio_codec_allowed_or_absent?(profile, audio_codec) ->
        "Incompatible audio codec (#{audio_codec || "unknown"})"

      not DeviceProfile.container_allowed?(profile, container) ->
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
