defmodule Mydia.Library.Structs.StreamInfo do
  @moduledoc """
  One elementary stream of a media file, as reported by `ffprobe -show_streams`.

  `Mydia.Library.FileAnalyzer` historically kept only the first video and first
  audio stream, collapsing them into the flat columns on `media_files`. This
  struct preserves every video, audio and subtitle stream so the player can show
  a full per-file readout.

  Values are stored as ffprobe reports them. Composing display strings
  ("HEVC Main 10", "7.1 (8 ch)", "23.976 fps") is the client's job, so the same
  data can be formatted differently by a future consumer without a server change.

  Attachment and data streams (embedded fonts, timecode tracks) are dropped: they
  are noise in a readout and would inflate the stored JSON.

  The disposition fields are named `is_default` / `is_forced` rather than
  `default` / `forced` because `default` is a reserved word in Dart, and these
  names reach the Flutter player verbatim through GraphQL codegen.
  """

  defstruct [
    # common
    :index,
    :type,
    :codec,
    :codec_long,
    :profile,
    :level,
    :language,
    :title,
    :bitrate,
    :is_default,
    :is_forced,
    :is_hearing_impaired,
    :is_commentary,
    # video
    :width,
    :height,
    :frame_rate,
    :pixel_format,
    :bit_depth,
    :color_space,
    :color_transfer,
    :color_primaries,
    :dolby_vision_profile,
    :dolby_vision_bl_compat_id,
    :aspect_ratio,
    # audio
    :channels,
    :channel_layout,
    :sample_rate
  ]

  @type stream_type :: :video | :audio | :subtitle

  @type t :: %__MODULE__{
          index: integer() | nil,
          type: stream_type() | nil,
          codec: String.t() | nil,
          codec_long: String.t() | nil,
          profile: String.t() | nil,
          level: integer() | nil,
          language: String.t() | nil,
          title: String.t() | nil,
          bitrate: integer() | nil,
          is_default: boolean() | nil,
          is_forced: boolean() | nil,
          is_hearing_impaired: boolean() | nil,
          is_commentary: boolean() | nil,
          width: integer() | nil,
          height: integer() | nil,
          frame_rate: float() | nil,
          pixel_format: String.t() | nil,
          bit_depth: integer() | nil,
          color_space: String.t() | nil,
          color_transfer: String.t() | nil,
          color_primaries: String.t() | nil,
          dolby_vision_profile: integer() | nil,
          dolby_vision_bl_compat_id: integer() | nil,
          aspect_ratio: String.t() | nil,
          channels: integer() | nil,
          channel_layout: String.t() | nil,
          sample_rate: integer() | nil
        }

  @known_keys ~w(
    index type codec codec_long profile level language title bitrate
    is_default is_forced is_hearing_impaired is_commentary
    width height frame_rate pixel_format bit_depth
    color_space color_transfer color_primaries dolby_vision_profile
    dolby_vision_bl_compat_id aspect_ratio
    channels channel_layout sample_rate
  )

  @doc """
  Builds a `StreamInfo` from one entry of ffprobe's `streams` array.

  Returns `nil` for stream kinds that do not belong in a readout (attachment,
  data) and for anything that is not a recognisable stream map.
  """
  @spec from_ffprobe_stream(map()) :: t() | nil
  def from_ffprobe_stream(%{"codec_type" => "video"} = stream), do: build(:video, stream)
  def from_ffprobe_stream(%{"codec_type" => "audio"} = stream), do: build(:audio, stream)
  def from_ffprobe_stream(%{"codec_type" => "subtitle"} = stream), do: build(:subtitle, stream)
  def from_ffprobe_stream(_stream), do: nil

  defp build(type, stream) do
    tags = normalize_tags(Map.get(stream, "tags"))
    disposition = Map.get(stream, "disposition")

    %__MODULE__{
      index: to_int(stream["index"]),
      type: type,
      codec: scrub_utf8(stream["codec_name"]),
      codec_long: scrub_utf8(stream["codec_long_name"]),
      profile: scrub_utf8(stream["profile"]),
      level: to_int(stream["level"]),
      language: scrub_utf8(tags["language"]),
      title: scrub_utf8(tags["title"]),
      bitrate: to_int(stream["bit_rate"]),
      is_default: flag(disposition, "default"),
      is_forced: flag(disposition, "forced"),
      is_hearing_impaired: flag(disposition, "hearing_impaired"),
      is_commentary: flag(disposition, "comment"),
      width: to_int(stream["width"]),
      height: to_int(stream["height"]),
      frame_rate: parse_rational(stream["avg_frame_rate"] || stream["r_frame_rate"]),
      pixel_format: stream["pix_fmt"],
      bit_depth: bit_depth(stream),
      color_space: stream["color_space"],
      color_transfer: stream["color_transfer"],
      color_primaries: stream["color_primaries"],
      dolby_vision_profile: dolby_vision_profile(stream),
      dolby_vision_bl_compat_id: dolby_vision_bl_compat_id(stream),
      aspect_ratio: stream["display_aspect_ratio"],
      channels: to_int(stream["channels"]),
      channel_layout: stream["channel_layout"],
      sample_rate: to_int(stream["sample_rate"])
    }
  end

  @doc """
  Converts to a plain string-keyed map for JSON storage.

  Nil fields are dropped so a subtitle stream does not serialise twenty null
  video fields. `false` is kept, since it is a meaningful disposition value.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = stream) do
    stream
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), encode(value)} end)
  end

  @doc """
  Rebuilds a `StreamInfo` from a stored string-keyed map. Unknown keys are
  ignored rather than raising, so data written by a future version loads.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    attrs =
      Enum.reduce(@known_keys, %{}, fn key, acc ->
        case fetch_either(map, key) do
          {:ok, value} -> Map.put(acc, String.to_existing_atom(key), decode(key, value))
          :error -> acc
        end
      end)

    struct(__MODULE__, attrs)
  end

  defp fetch_either(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, String.to_existing_atom(key))
    end
  end

  defp encode(value) when is_boolean(value), do: value
  defp encode(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp encode(value), do: value

  defp decode("type", "video"), do: :video
  defp decode("type", "audio"), do: :audio
  defp decode("type", "subtitle"), do: :subtitle
  defp decode("type", value) when is_atom(value), do: value
  defp decode("type", _value), do: nil
  defp decode(_key, value), do: value

  defp normalize_tags(tags) when is_map(tags) do
    # Matroska commonly writes tag names in upper case (LANGUAGE, TITLE).
    Map.new(tags, fn {key, value} -> {String.downcase(to_string(key)), value} end)
  end

  defp normalize_tags(_tags), do: %{}

  defp flag(disposition, key) when is_map(disposition), do: Map.get(disposition, key) == 1
  defp flag(_disposition, _key), do: false

  # ffprobe reports frame rates as a rational string such as "24000/1001".
  defp parse_rational(value) when is_binary(value) do
    with [numerator, denominator] <- String.split(value, "/"),
         {num, ""} <- Integer.parse(numerator),
         {den, ""} <- Integer.parse(denominator),
         true <- den != 0 do
      Float.round(num / den, 3)
    else
      _ -> nil
    end
  end

  defp parse_rational(_value), do: nil

  defp bit_depth(stream) do
    case to_int(stream["bits_per_raw_sample"]) do
      nil -> bit_depth_from_pixel_format(stream["pix_fmt"])
      depth -> depth
    end
  end

  defp bit_depth_from_pixel_format(pix_fmt) when is_binary(pix_fmt) do
    case Regex.run(~r/p(\d+)(?:le|be)?$/, pix_fmt) do
      [_full, depth] -> String.to_integer(depth)
      nil -> if String.starts_with?(pix_fmt, "yuv"), do: 8, else: nil
    end
  end

  defp bit_depth_from_pixel_format(_pix_fmt), do: nil

  # Dolby Vision is signalled by a DOVI configuration record in side data.
  # Matching on the presence of dv_profile is more robust than the type string.
  defp dolby_vision_profile(stream) do
    stream
    |> Map.get("side_data_list")
    |> List.wrap()
    |> Enum.find_value(fn
      %{"dv_profile" => profile} -> to_int(profile)
      _other -> nil
    end)
  end

  # The base-layer compatibility id distinguishes DV 8.1 (HDR10 base) from
  # 8.4 (HLG base) and 5 (no compatible base). Read from the same record as
  # dv_profile.
  defp dolby_vision_bl_compat_id(stream) do
    stream
    |> Map.get("side_data_list")
    |> List.wrap()
    |> Enum.find_value(fn
      %{"dv_bl_signal_compatibility_id" => id} -> to_int(id)
      _other -> nil
    end)
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp to_int(_value), do: nil

  # Container tags carry arbitrary bytes. Raw non-UTF-8 passes silently on
  # SQLite and raises on PostgreSQL in the `:string` metadata column, so
  # anything invalid is reinterpreted as latin1, which always yields valid UTF-8.
  defp scrub_utf8(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      case :unicode.characters_to_binary(value, :latin1, :utf8) do
        converted when is_binary(converted) -> converted
        _error -> nil
      end
    end
  end

  defp scrub_utf8(_value), do: nil
end
