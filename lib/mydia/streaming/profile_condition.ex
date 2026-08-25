defmodule Mydia.Streaming.ProfileCondition do
  @moduledoc """
  One constraint a client places on a codec it claims to decode.

  A codec name alone cannot answer "can this device play this file". A tablet
  whose MediaCodec decodes HEVC Main happily rejects the same codec at Main 10,
  and libmpv's `decoder-list` — which is what the native client probes — reports
  what libavcodec was *compiled* with, so it says "hevc" either way. Conditions
  are how a client says the rest of it: bit depth, profile, level, resolution,
  frame rate, channel count.

  The shape mirrors Jellyfin's `ProfileCondition` (and Plex's device profiles)
  rather than inventing a Mydia dialect, so the vocabulary is one an operator
  may already know and a future importer can map onto directly.

  ## Evaluating against absent metadata

  A condition whose property cannot be resolved from the file's stream data is
  **not** silently satisfied. `required: true` (the default) fails closed, which
  is the only safe direction: the alternative hands the client a stream it never
  approved and dead-ends playback on an error screen it cannot recover from.
  `required: false` marks a preference that an unknown value may pass.

  Read the property values from `Mydia.Library.Structs.StreamInfo`, never from
  the flat `FileMetadata` codec-detail fields (`hevc_profile_idc`, `bit_depth`).
  Those are declared but never written by the analyzer — across a 1291-file
  production HEVC library they are populated on zero rows, while the per-stream
  values are populated on all of them. A condition sourced from the flat fields
  would resolve to `nil` everywhere and, under `required: false`, pass
  everything while appearing to validate.
  """

  alias Mydia.Library.Structs.StreamInfo

  @enforce_keys [:property, :condition, :value]
  defstruct [:property, :condition, :value, required: true]

  @type property ::
          :video_bit_depth
          | :video_profile
          | :video_level
          | :width
          | :height
          | :video_framerate
          | :audio_channels
          | :audio_sample_rate
          | :audio_profile

  @type condition ::
          :equals | :not_equals | :less_than_equal | :greater_than_equal | :equals_any

  @type t :: %__MODULE__{
          property: property(),
          condition: condition(),
          value: String.t(),
          required: boolean()
        }

  # Fixed enums, looked up rather than converted. The payload is
  # attacker-controlled and these read exactly like atom names, which is the
  # shape that invites an unsafe String.to_atom/1 and a memory leak with it.
  # An unrecognized name resolves to :invalid, never to a minted atom.
  @properties %{
    "videobitdepth" => :video_bit_depth,
    "videoprofile" => :video_profile,
    "videolevel" => :video_level,
    "width" => :width,
    "height" => :height,
    "videoframerate" => :video_framerate,
    "audiochannels" => :audio_channels,
    "audiosamplerate" => :audio_sample_rate,
    "audioprofile" => :audio_profile
  }

  @conditions %{
    "equals" => :equals,
    "notequals" => :not_equals,
    "lessthanequal" => :less_than_equal,
    "greaterthanequal" => :greater_than_equal,
    "equalsany" => :equals_any
  }

  # Properties compared as numbers. Everything else compares as a
  # case-insensitive string, which is what "Main 10" needs.
  @numeric [
    :video_bit_depth,
    :video_level,
    :width,
    :height,
    :video_framerate,
    :audio_channels,
    :audio_sample_rate
  ]

  @doc "Parses a property name. Unrecognized names return `:invalid`."
  @spec parse_property(term()) :: property() | :invalid
  def parse_property(name) when is_binary(name) do
    Map.get(@properties, name |> String.trim() |> String.downcase(), :invalid)
  end

  def parse_property(_name), do: :invalid

  @doc "Parses a condition name. Unrecognized names return `:invalid`."
  @spec parse_condition(term()) :: condition() | :invalid
  def parse_condition(name) when is_binary(name) do
    Map.get(@conditions, name |> String.trim() |> String.downcase(), :invalid)
  end

  def parse_condition(_name), do: :invalid

  @doc """
  Builds a condition from a decoded JSON map.

  Returns `:error` for an unknown property or condition rather than dropping the
  entry. A silently dropped constraint is indistinguishable from a client that
  never had one, which would widen direct play instead of narrowing it.
  """
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(%{} = map) do
    property = parse_property(Map.get(map, "property"))
    condition = parse_condition(Map.get(map, "condition"))
    value = Map.get(map, "value")

    cond do
      property == :invalid -> :error
      condition == :invalid -> :error
      not is_binary(value) or value == "" -> :error
      true -> {:ok, build(property, condition, value, Map.get(map, "isRequired", true))}
    end
  end

  def from_map(_other), do: :error

  defp build(property, condition, value, required) do
    %__MODULE__{
      property: property,
      condition: condition,
      value: value,
      # Anything that is not an explicit `false` keeps the fail-closed default.
      required: required != false
    }
  end

  @doc """
  Whether `stream` satisfies this condition.

  An unresolvable property fails when `required` is set, and passes when it is
  not. See the moduledoc for why the default leans that way.
  """
  @spec satisfied?(t(), StreamInfo.t() | nil) :: boolean()
  def satisfied?(%__MODULE__{} = condition, stream) do
    case resolve(condition.property, stream) do
      nil -> not condition.required
      actual -> compare(condition, actual)
    end
  end

  defp resolve(_property, nil), do: nil
  defp resolve(:video_bit_depth, %StreamInfo{bit_depth: value}), do: value
  defp resolve(:video_profile, %StreamInfo{profile: value}), do: value
  defp resolve(:video_level, %StreamInfo{level: value}), do: value
  defp resolve(:width, %StreamInfo{width: value}), do: value
  defp resolve(:height, %StreamInfo{height: value}), do: value
  defp resolve(:video_framerate, %StreamInfo{frame_rate: value}), do: value
  defp resolve(:audio_channels, %StreamInfo{channels: value}), do: value
  defp resolve(:audio_sample_rate, %StreamInfo{sample_rate: value}), do: value
  defp resolve(:audio_profile, %StreamInfo{profile: value}), do: value
  defp resolve(_property, _stream), do: nil

  # Handled before the single-number parse below: an `equals_any` value is a
  # "8|10" list, which never parses as one number and would otherwise be
  # rejected as malformed.
  defp compare(%__MODULE__{property: property, condition: :equals_any} = condition, actual)
       when property in @numeric do
    case to_number(actual) do
      {:ok, actual} ->
        condition.value
        |> split_any()
        |> Enum.any?(&match?({:ok, ^actual}, to_number(&1)))

      :error ->
        not condition.required
    end
  end

  defp compare(%__MODULE__{property: property} = condition, actual)
       when property in @numeric do
    with {:ok, expected} <- to_number(condition.value),
         {:ok, actual} <- to_number(actual) do
      numeric_compare(condition, expected, actual)
    else
      # A non-numeric value on a numeric property is a malformed condition, and
      # a malformed constraint must not widen direct play.
      :error -> not condition.required
    end
  end

  defp compare(condition, actual), do: string_compare(condition, actual)

  defp numeric_compare(%__MODULE__{condition: :equals}, expected, actual),
    do: actual == expected

  defp numeric_compare(%__MODULE__{condition: :not_equals}, expected, actual),
    do: actual != expected

  defp numeric_compare(%__MODULE__{condition: :less_than_equal}, expected, actual),
    do: actual <= expected

  defp numeric_compare(%__MODULE__{condition: :greater_than_equal}, expected, actual),
    do: actual >= expected

  defp string_compare(%__MODULE__{condition: :equals_any} = condition, actual) do
    normalized = normalize(actual)

    condition.value
    |> split_any()
    |> Enum.any?(&(normalize(&1) == normalized))
  end

  defp string_compare(%__MODULE__{condition: :equals} = condition, actual),
    do: normalize(actual) == normalize(condition.value)

  defp string_compare(%__MODULE__{condition: :not_equals} = condition, actual),
    do: normalize(actual) != normalize(condition.value)

  # Ordering comparisons are meaningless on a free-text profile name. Treat them
  # as malformed rather than inventing a lexicographic answer that would read as
  # a real capability check.
  defp string_compare(%__MODULE__{} = condition, _actual), do: not condition.required

  defp split_any(value) do
    value
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp to_number(value) when is_integer(value) or is_float(value), do: {:ok, value * 1.0}

  defp to_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp to_number(_value), do: :error
end
