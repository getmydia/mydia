defmodule Mydia.Library.Structs.FileMetadata do
  @moduledoc """
  Technical metadata extracted from media files via FFprobe.

  This struct replaces the plain `map()` previously used for `MediaFile.metadata`,
  providing compile-time safety for field access. All fields are optional because
  metadata is incrementally populated — FFprobe may not extract all fields for
  every format.

  ## Field Groups

  - **Core technical**: duration, container, format_name, width, height, source
  - **Lossless audio description**: audio_codec_raw (see the field comment)
  - **H.264/AVC codec details**: video_profile_idc, video_level_idc, video_constraint_set
  - **HEVC/H.265 codec details**: hevc_profile_idc, hevc_tier_flag, hevc_level_idc
  - **VP9 codec details**: vp9_profile, vp9_level
  - **AV1 codec details**: av1_profile, av1_level, av1_tier
  - **Shared codec detail**: bit_depth
  - **Streams**: streams (per-stream detail, see `Mydia.Library.Structs.StreamInfo`)
  - **Quality evaluation**: quality_evaluation (written by QualityProfileEngine)
  - **Catch-all**: extra (captures unknown keys from legacy data or future ffprobe versions)
  """

  alias Mydia.Library.Structs.StreamInfo

  defstruct [
    # Core technical
    :duration,
    :container,
    :format_name,
    :width,
    :height,
    :source,

    # The analyzer's full audio description, e.g. "DD+ 5.1" or "TrueHD Atmos",
    # kept verbatim. The `media_files.audio_codec` column holds
    # `Mydia.Streaming.Codec.normalize_audio_codec/1`'s output, which collapses
    # both of those to a bare codec ("ac3", "truehd"), dropping the channel
    # layout and the Atmos/E-AC3 distinction. That is the right shape for
    # streaming-compatibility checks and the wrong shape for quality scoring,
    # so the lossless string is preserved here for `Mydia.Upgrades.Attrs`.
    :audio_codec_raw,

    # H.264/AVC codec details
    :video_profile_idc,
    :video_level_idc,
    :video_constraint_set,

    # HEVC codec details
    :hevc_profile_idc,
    :hevc_tier_flag,
    :hevc_level_idc,

    # VP9 codec details
    :vp9_profile,
    :vp9_level,

    # AV1 codec details
    :av1_profile,
    :av1_level,
    :av1_tier,

    # Shared codec detail
    :bit_depth,

    # Every video, audio and subtitle stream. nil means capture has never run
    # for this file; [] means it ran and found nothing usable. The repair lane
    # in Mydia.Jobs.FileAnalysis keys off nil, so writing [] is what stops a
    # pathological file being re-probed on every tick forever.
    :streams,

    # Quality evaluation (written by QualityProfileEngine)
    :quality_evaluation,

    # Catch-all for unknown/future ffprobe fields
    extra: %{}
  ]

  @type t :: %__MODULE__{
          duration: float() | nil,
          container: String.t() | nil,
          format_name: String.t() | nil,
          width: integer() | nil,
          height: integer() | nil,
          source: String.t() | nil,
          audio_codec_raw: String.t() | nil,
          video_profile_idc: integer() | nil,
          video_level_idc: integer() | nil,
          video_constraint_set: integer() | nil,
          hevc_profile_idc: integer() | nil,
          hevc_tier_flag: integer() | nil,
          hevc_level_idc: integer() | nil,
          vp9_profile: integer() | nil,
          vp9_level: integer() | nil,
          av1_profile: integer() | nil,
          av1_level: integer() | nil,
          av1_tier: integer() | nil,
          bit_depth: integer() | nil,
          streams: [StreamInfo.t()] | nil,
          quality_evaluation: map() | nil,
          extra: map()
        }

  # Known fields for safe string-to-atom conversion (whitelist approach)
  @known_keys %{
    "duration" => :duration,
    "container" => :container,
    "format_name" => :format_name,
    "width" => :width,
    "height" => :height,
    "source" => :source,
    "audio_codec_raw" => :audio_codec_raw,
    "video_profile_idc" => :video_profile_idc,
    "video_level_idc" => :video_level_idc,
    "video_constraint_set" => :video_constraint_set,
    "hevc_profile_idc" => :hevc_profile_idc,
    "hevc_tier_flag" => :hevc_tier_flag,
    "hevc_level_idc" => :hevc_level_idc,
    "vp9_profile" => :vp9_profile,
    "vp9_level" => :vp9_level,
    "av1_profile" => :av1_profile,
    "av1_level" => :av1_level,
    "av1_tier" => :av1_tier,
    "bit_depth" => :bit_depth,
    "streams" => :streams,
    "quality_evaluation" => :quality_evaluation
  }

  @doc """
  Creates a FileMetadata struct from a plain map with string or atom keys.

  Unknown keys are collected into the `extra` field to prevent data loss
  when loading legacy data or handling future ffprobe versions.
  """
  def from_map(nil), do: empty()

  def from_map(map) when is_map(map) do
    {known, extra} =
      Enum.reduce(map, {%{}, %{}}, fn {key, value}, {known_acc, extra_acc} ->
        case resolve_key(key) do
          {:known, :streams} ->
            {Map.put(known_acc, :streams, normalize_streams(value)), extra_acc}

          {:known, atom_key} ->
            {Map.put(known_acc, atom_key, value), extra_acc}

          :unknown ->
            {known_acc, Map.put(extra_acc, to_string(key), value)}
        end
      end)

    struct(__MODULE__, Map.put(known, :extra, extra))
  end

  # `streams` arrives either as StreamInfo structs (from the analyzer, via
  # Ecto.Type.cast/1) or as plain maps (from stored JSON, via load/1).
  #
  # Anything else in the list is dropped rather than raised on. This runs on
  # every metadata load, so a single malformed entry in a hand-edited or legacy
  # JSON column would otherwise crash reads and repairs for that file instead of
  # costing it one stream.
  defp normalize_streams(streams) when is_list(streams) do
    Enum.flat_map(streams, fn
      %StreamInfo{} = stream -> [stream]
      map when is_map(map) -> [StreamInfo.from_map(map)]
      _other -> []
    end)
  end

  defp normalize_streams(_streams), do: nil

  @doc """
  Creates an empty FileMetadata with all fields set to nil.
  """
  def empty, do: %__MODULE__{}

  @doc """
  Converts the struct back to a plain map with string keys for JSON serialization.

  Merges the `extra` field back into the top-level map so unknown keys are preserved.
  """
  def to_map(%__MODULE__{} = metadata) do
    metadata
    |> Map.from_struct()
    |> Map.delete(:extra)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn
      {:streams, streams} -> {"streams", Enum.map(streams, &StreamInfo.to_map/1)}
      {k, v} -> {to_string(k), v}
    end)
    |> Map.new()
    |> Map.merge(metadata.extra || %{})
  end

  defp resolve_key(key) when is_atom(key) do
    string_key = to_string(key)

    case Map.get(@known_keys, string_key) do
      nil -> :unknown
      atom_key -> {:known, atom_key}
    end
  end

  defp resolve_key(key) when is_binary(key) do
    case Map.get(@known_keys, key) do
      nil -> :unknown
      atom_key -> {:known, atom_key}
    end
  end

  defp resolve_key(_key), do: :unknown
end
