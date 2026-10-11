defmodule Mydia.Streaming.CodecString do
  @moduledoc """
  Generates RFC 6381 compliant codec strings for use in MIME types.

  RFC 6381 defines the 'codecs' parameter for media type containers,
  specifying how to encode codec information in a standardized way.

  This module generates codec strings from FFprobe metadata that can be
  used with browser APIs like:
  - MediaCapabilities API
  - MediaSource.isTypeSupported()
  - HTMLMediaElement.canPlayType()

  ## Examples

      iex> CodecString.video_codec_string("H.264 (Main)", %{})
      "avc1.4d4028"

      iex> CodecString.video_codec_string("HEVC (Main 10)", %{})
      "hvc1.2.4.L120.B0"

      iex> CodecString.audio_codec_string("AAC Stereo", %{})
      "mp4a.40.2"

  ## References

  - RFC 6381: https://datatracker.ietf.org/doc/html/rfc6381
  - ISO/IEC 14496-15 (AVC/HEVC file format)
  - VP9 codec string: https://www.webmproject.org/vp9/mp4/
  - AV1 codec string: https://aomediacodec.github.io/av1-isobmff/
  """

  @doc """
  Generates an RFC 6381 video codec string from FFprobe-derived codec information.

  ## Parameters

  - `codec` - Human-readable codec string from FFprobe (e.g., "H.264 (High)", "HEVC (Main)")
  - `metadata` - Optional map with additional codec details from FFprobe:
    - `"video_profile_idc"` - H.264/AVC profile indicator (integer)
    - `"video_level_idc"` - H.264/AVC level indicator (integer)
    - `"video_constraint_set"` - H.264/AVC constraint set flags (integer)
    - `"hevc_profile_space"` - HEVC profile space (0-3)
    - `"hevc_profile_idc"` - HEVC profile indicator (1=Main, 2=Main10, etc.)
    - `"hevc_tier_flag"` - HEVC tier (0=Main, 1=High)
    - `"hevc_level_idc"` - HEVC level indicator (integer, e.g., 120 for Level 4.0)
    - `"bit_depth"` - Bit depth (8, 10, 12)

  ## Returns

  A string suitable for use in MIME type codecs parameter, e.g., "avc1.4d4028"
  """
  @spec video_codec_string(String.t() | nil, map()) :: String.t() | nil
  def video_codec_string(nil, _metadata), do: nil

  def video_codec_string(codec, metadata) when is_binary(codec) do
    normalized = String.downcase(codec)

    cond do
      h264?(normalized) -> h264_codec_string(codec, metadata)
      hevc?(normalized) -> hevc_codec_string(codec, metadata)
      vp9?(normalized) -> vp9_codec_string(metadata)
      vp8?(normalized) -> "vp8"
      av1?(normalized) -> av1_codec_string(metadata)
      true -> nil
    end
  end

  @doc """
  Generates an RFC 6381 audio codec string from FFprobe-derived codec information.

  ## Parameters

  - `audio_codec` - Human-readable audio codec string (e.g., "AAC Stereo", "DTS-HD MA 5.1")
  - `metadata` - Optional map with additional codec details

  ## Returns

  A string suitable for use in MIME type codecs parameter, e.g., "mp4a.40.2"
  """
  @spec audio_codec_string(String.t() | nil, map()) :: String.t() | nil
  def audio_codec_string(nil, _metadata), do: nil

  def audio_codec_string(audio_codec, _metadata) when is_binary(audio_codec) do
    normalized = String.downcase(audio_codec)

    cond do
      aac?(normalized) -> aac_codec_string(audio_codec)
      mp3?(normalized) -> "mp4a.40.34"
      ac3?(normalized) -> "ac-3"
      eac3?(normalized) -> "ec-3"
      dts?(normalized) -> nil
      truehd?(normalized) -> nil
      opus?(normalized) -> "opus"
      vorbis?(normalized) -> "vorbis"
      flac?(normalized) -> "flac"
      pcm?(normalized) -> nil
      true -> nil
    end
  end

  @doc """
  Builds a complete MIME type string with codecs parameter.

  ## Parameters

  - `container` - Container format ("mp4", "webm", etc.)
  - `video_codec_str` - RFC 6381 video codec string (from `video_codec_string/2`)
  - `audio_codec_str` - RFC 6381 audio codec string (from `audio_codec_string/2`)

  ## Returns

  A MIME type string like: `video/mp4; codecs="avc1.4d4028, mp4a.40.2"`
  """
  @spec build_mime_type(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  def build_mime_type(container, video_codec_str, audio_codec_str) do
    base_type = container_to_mime(container)

    codecs =
      [video_codec_str, audio_codec_str]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    if codecs == "" do
      base_type
    else
      ~s(#{base_type}; codecs="#{codecs}")
    end
  end

  @doc """
  Generates multiple codec string variants for browser compatibility testing.

  Different browsers may accept different forms of the same codec string.
  This function returns a list of variants from most specific to most generic.

  ## Returns

  A list of codec strings, ordered from most specific to most generic.
  """
  @spec video_codec_variants(String.t() | nil, map()) :: [String.t()]
  def video_codec_variants(nil, _metadata), do: []

  def video_codec_variants(codec, metadata) when is_binary(codec) do
    normalized = String.downcase(codec)

    cond do
      h264?(normalized) -> h264_variants(codec, metadata)
      hevc?(normalized) -> hevc_variants(codec, metadata)
      vp9?(normalized) -> vp9_variants(metadata)
      vp8?(normalized) -> ["vp8"]
      av1?(normalized) -> av1_variants(metadata)
      true -> []
    end
  end

  # ============================================================================
  # H.264/AVC Codec String Generation
  # ============================================================================

  # H.264 codec string format: avc1.PPCCLL
  # PP = profile_idc (hex)
  # CC = constraint_set flags (hex)
  # LL = level_idc (hex)

  defp h264_codec_string(codec, metadata) do
    # Try to use raw FFprobe values if available
    case metadata do
      %{video_profile_idc: profile_idc, video_level_idc: level_idc}
      when not is_nil(profile_idc) and not is_nil(level_idc) ->
        constraint = metadata.video_constraint_set || 0
        format_avc1(profile_idc, constraint, level_idc)

      _ ->
        # Fall back to deriving from human-readable profile name
        {profile_idc, constraint, level_idc} = h264_profile_to_idc(codec)
        format_avc1(profile_idc, constraint, level_idc)
    end
  end

  defp format_avc1(profile_idc, constraint, level_idc) do
    "avc1.#{hex2(profile_idc)}#{hex2(constraint)}#{hex2(level_idc)}"
  end

  defp hex2(value) when is_integer(value) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(2, "0")
  end

  # Map human-readable H.264 profile names to {profile_idc, constraint, level_idc}
  # Default level is 4.0 (40 in level_idc = 0x28) which covers 1080p @ 30fps
  @h264_default_level 40

  defp h264_profile_to_idc(codec) do
    normalized = String.downcase(codec)

    cond do
      # Constrained Baseline (profile_idc=66, constraint_set1=1)
      String.contains?(normalized, "constrained baseline") ->
        {66, 0x40, @h264_default_level}

      # Baseline (profile_idc=66)
      String.contains?(normalized, "baseline") ->
        {66, 0x00, @h264_default_level}

      # Main (profile_idc=77)
      String.contains?(normalized, "main") ->
        {77, 0x00, @h264_default_level}

      # High 10 (profile_idc=110)
      String.contains?(normalized, "high 10") or String.contains?(normalized, "high10") ->
        {110, 0x00, @h264_default_level}

      # High 4:2:2 (profile_idc=122)
      String.contains?(normalized, "high 4:2:2") or String.contains?(normalized, "high422") ->
        {122, 0x00, @h264_default_level}

      # High 4:4:4 (profile_idc=244)
      String.contains?(normalized, "high 4:4:4") or String.contains?(normalized, "high444") ->
        {244, 0x00, @h264_default_level}

      # High (profile_idc=100) - most common for consumer video
      String.contains?(normalized, "high") ->
        {100, 0x00, @h264_default_level}

      # Default to High profile for generic H.264
      true ->
        {100, 0x00, @h264_default_level}
    end
  end

  defp h264_variants(codec, metadata) do
    primary = h264_codec_string(codec, metadata)

    # Also include a generic fallback that works in most browsers
    [
      primary,
      "avc1.640028",
      "avc1.4d4028",
      "avc1"
    ]
    |> Enum.uniq()
  end

  # ============================================================================
  # HEVC/H.265 Codec String Generation
  # ============================================================================

  # HEVC codec string format: hvc1.P.C.TLL.XX or hev1.P.C.TLL.XX
  # P = profile_space (0-3, usually 0 means no prefix)
  # C = profile_idc (general_profile_idc)
  # T = tier_flag (L=Main tier, H=High tier)
  # LL = level_idc (e.g., 120 for Level 4.0)
  # XX = constraint flags (usually B0 for general compatibility)
  #
  # hvc1 = codec configuration in sample entries
  # hev1 = in-band parameter sets

  defp hevc_codec_string(codec, metadata) do
    # Try to use raw FFprobe values if available
    case metadata do
      %{hevc_profile_idc: profile_idc, hevc_level_idc: level_idc}
      when not is_nil(profile_idc) and not is_nil(level_idc) ->
        tier = metadata.hevc_tier_flag || 0
        format_hevc("hvc1", profile_idc, tier, level_idc)

      _ ->
        # Fall back to deriving from human-readable profile name
        {profile_idc, tier, level_idc} = hevc_profile_to_idc(codec)
        format_hevc("hvc1", profile_idc, tier, level_idc)
    end
  end

  defp format_hevc(prefix, profile_idc, tier, level_idc) do
    tier_char = if tier == 1, do: "H", else: "L"
    # Profile compatibility is a 32-bit field, we use a simple default
    # 4 for Main, 6 for Main10 are common values
    compat = hevc_profile_compatibility(profile_idc)
    "#{prefix}.#{profile_idc}.#{compat}.#{tier_char}#{level_idc}.B0"
  end

  defp hevc_profile_compatibility(1), do: 4
  defp hevc_profile_compatibility(2), do: 4
  defp hevc_profile_compatibility(_), do: 4

  # Map human-readable HEVC profile names to {profile_idc, tier_flag, level_idc}
  # Default level is 4.0 (level_idc=120) which covers 1080p @ 60fps or 4K @ 30fps
  @hevc_default_level 120

  defp hevc_profile_to_idc(codec) do
    normalized = String.downcase(codec)

    cond do
      # Main 10 (profile_idc=2) - 10-bit HDR content
      String.contains?(normalized, "main 10") or String.contains?(normalized, "main10") ->
        {2, 0, @hevc_default_level}

      # Main Still Picture (profile_idc=3)
      String.contains?(normalized, "still") ->
        {3, 0, @hevc_default_level}

      # Main (profile_idc=1) - standard 8-bit content
      String.contains?(normalized, "main") ->
        {1, 0, @hevc_default_level}

      # Rext profiles - default to Main 10 for safety
      String.contains?(normalized, "rext") ->
        {2, 0, @hevc_default_level}

      # Default to Main profile
      true ->
        {1, 0, @hevc_default_level}
    end
  end

  defp hevc_variants(codec, metadata) do
    primary = hevc_codec_string(codec, metadata)
    {profile_idc, tier, level_idc} = hevc_profile_to_idc(codec)

    # hev1 variant (in-band parameters)
    hev1 = format_hevc("hev1", profile_idc, tier, level_idc)

    [
      primary,
      hev1,
      # Simpler format sometimes accepted
      "hvc1.1.6.L93.B0",
      "hev1.1.6.L93.B0",
      "hvc1",
      "hev1"
    ]
    |> Enum.uniq()
  end

  # ============================================================================
  # VP9 Codec String Generation
  # ============================================================================

  # VP9 codec string format: vp09.PP.LL.DD.CC.CP.TC.MC.FF
  # PP = profile (00, 01, 02, 03)
  # LL = level (e.g., 31 for 1080p30)
  # DD = bit depth (08, 10, 12)
  # (remaining fields often omitted for browser compatibility)

  defp vp9_codec_string(metadata) do
    profile = metadata.vp9_profile || 0
    level = metadata.vp9_level || 31
    bit_depth = metadata.bit_depth || 8

    "vp09.#{pad2(profile)}.#{pad2(level)}.#{pad2(bit_depth)}"
  end

  defp pad2(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end

  defp vp9_variants(metadata) do
    primary = vp9_codec_string(metadata)

    [
      primary,
      "vp09.00.31.08",
      "vp9"
    ]
    |> Enum.uniq()
  end

  # ============================================================================
  # AV1 Codec String Generation
  # ============================================================================

  # AV1 codec string format: av01.P.LLT.DD
  # P = profile (0=Main, 1=High, 2=Professional)
  # LL = level (e.g., 09 for Level 3.1)
  # T = tier (M=Main, H=High)
  # DD = bit depth (08, 10, 12)

  defp av1_codec_string(metadata) do
    profile = metadata.av1_profile || 0
    level = metadata.av1_level || 9
    tier = if (metadata.av1_tier || 0) == 1, do: "H", else: "M"
    bit_depth = metadata.bit_depth || 8

    "av01.#{profile}.#{pad2(level)}#{tier}.#{pad2(bit_depth)}"
  end

  defp av1_variants(metadata) do
    primary = av1_codec_string(metadata)

    [
      primary,
      "av01.0.08M.08",
      "av01.0.00M.08",
      "av01"
    ]
    |> Enum.uniq()
  end

  # ============================================================================
  # Audio Codec String Generation
  # ============================================================================

  defp aac_codec_string(audio_codec) do
    normalized = String.downcase(audio_codec)

    cond do
      # AAC HE (High Efficiency) - object type 5
      String.contains?(normalized, "he-aac") or String.contains?(normalized, "aac-he") ->
        "mp4a.40.5"

      # AAC HE v2 - object type 29
      String.contains?(normalized, "he-aac") and String.contains?(normalized, "v2") ->
        "mp4a.40.29"

      # AAC-LC (Low Complexity) - object type 2 - most common
      true ->
        "mp4a.40.2"
    end
  end

  # ============================================================================
  # Codec Detection Helpers
  # ============================================================================

  defp h264?(codec) do
    String.contains?(codec, "h264") or
      String.contains?(codec, "h.264") or
      String.contains?(codec, "avc")
  end

  defp hevc?(codec) do
    String.contains?(codec, "hevc") or
      String.contains?(codec, "h265") or
      String.contains?(codec, "h.265")
  end

  defp vp9?(codec), do: String.contains?(codec, "vp9")
  defp vp8?(codec), do: String.contains?(codec, "vp8")
  defp av1?(codec), do: String.contains?(codec, "av1")

  defp aac?(codec), do: String.contains?(codec, "aac")
  defp mp3?(codec), do: String.contains?(codec, "mp3")
  defp ac3?(codec), do: String.contains?(codec, "ac3") and not String.contains?(codec, "eac3")
  defp eac3?(codec), do: String.contains?(codec, "eac3") or String.contains?(codec, "dd+")
  defp dts?(codec), do: String.contains?(codec, "dts")
  defp truehd?(codec), do: String.contains?(codec, "truehd")
  defp opus?(codec), do: String.contains?(codec, "opus")
  defp vorbis?(codec), do: String.contains?(codec, "vorbis")
  defp flac?(codec), do: String.contains?(codec, "flac")
  defp pcm?(codec), do: String.contains?(codec, "pcm")

  # ============================================================================
  # Container MIME Type Mapping
  # ============================================================================

  defp container_to_mime("mp4"), do: "video/mp4"
  defp container_to_mime("m4v"), do: "video/mp4"
  defp container_to_mime("mov"), do: "video/mp4"
  defp container_to_mime("mkv"), do: "video/x-matroska"
  defp container_to_mime("webm"), do: "video/webm"
  defp container_to_mime("ts"), do: "video/mp2t"
  defp container_to_mime("avi"), do: "video/x-msvideo"
  defp container_to_mime(_), do: "video/mp4"
end
