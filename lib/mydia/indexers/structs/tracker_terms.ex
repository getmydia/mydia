defmodule Mydia.Indexers.Structs.TrackerTerms do
  @moduledoc """
  What a tracker asks of a release: whether it is private, the minimum ratio
  and seed time it requires, and how much of the download and upload count
  toward the account's ratio (the volume factors).

  Every field may be nil, which means unknown, never "no requirement".
  `minimum_seed_time` is in seconds. A download volume factor of 0 is
  freeleech, 0.5 is half leech; an upload factor of 2 is double upload.

  Adapters fill this from whatever their protocol carries (see
  `lib/mydia/indexers/README.md`, "Tracker terms"). Operator overrides are
  applied by `Mydia.Indexers.TrackerRules.effective/3`, and the effective
  terms are frozen into `Download.metadata["tracker_terms"]` at grab through
  `to_map/1`.
  """

  @type t :: %__MODULE__{
          private?: boolean() | nil,
          minimum_ratio: float() | nil,
          minimum_seed_time: non_neg_integer() | nil,
          download_volume_factor: float() | nil,
          upload_volume_factor: float() | nil
        }

  defstruct [
    :private?,
    :minimum_ratio,
    :minimum_seed_time,
    :download_volume_factor,
    :upload_volume_factor
  ]

  # Struct field to the key it is stored under. `private?` is spelled without
  # the question mark outside Elixir.
  @map_keys [
    private?: "private",
    minimum_ratio: "minimum_ratio",
    minimum_seed_time: "minimum_seed_time",
    download_volume_factor: "download_volume_factor",
    upload_volume_factor: "upload_volume_factor"
  ]

  @doc """
  Builds terms from Torznab/Newznab attribute values keyed by attribute name
  (`downloadvolumefactor`, `uploadvolumefactor`, `minimumratio`,
  `minimumseedtime`). Returns nil when none of them carries a value.
  """
  @spec from_torznab(%{optional(String.t()) => String.t() | nil}) :: t() | nil
  def from_torznab(attrs) when is_map(attrs) do
    %__MODULE__{
      download_volume_factor: parse_float(attrs["downloadvolumefactor"]),
      upload_volume_factor: parse_float(attrs["uploadvolumefactor"]),
      minimum_ratio: parse_float(attrs["minimumratio"]),
      minimum_seed_time: parse_seconds(attrs["minimumseedtime"])
    }
    |> nil_if_empty()
  end

  @doc "Returns nil for terms that carry no known value."
  @spec nil_if_empty(t() | nil) :: t() | nil
  def nil_if_empty(terms), do: if(empty?(terms), do: nil, else: terms)

  @doc "True when no field is known."
  @spec empty?(t() | nil) :: boolean()
  def empty?(nil), do: true

  def empty?(%__MODULE__{} = terms),
    do: Enum.all?(Keyword.keys(@map_keys), &is_nil(Map.fetch!(terms, &1)))

  @doc "The terms as a JSON-safe map with string keys, for `Download.metadata`."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = terms),
    do: Map.new(@map_keys, fn {field, key} -> {key, Map.fetch!(terms, field)} end)

  @doc "Reads terms back from `to_map/1` output, with string or atom keys."
  @spec from_map(map() | nil) :: t() | nil
  def from_map(nil), do: nil

  def from_map(map) when is_map(map) do
    value = fn key -> Map.get(map, key, Map.get(map, String.to_existing_atom(key))) end

    %__MODULE__{
      private?: boolean(value.("private")),
      minimum_ratio: parse_float(value.("minimum_ratio")),
      minimum_seed_time: parse_seconds(value.("minimum_seed_time")),
      download_volume_factor: parse_float(value.("download_volume_factor")),
      upload_volume_factor: parse_float(value.("upload_volume_factor"))
    }
  end

  @doc "A non-negative float from a number or numeric string; anything else is nil."
  @spec parse_float(term()) :: float() | nil
  def parse_float(value) when is_float(value) and value >= 0, do: value
  def parse_float(value) when is_integer(value) and value >= 0, do: value * 1.0

  def parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> parse_float(number)
      _ -> nil
    end
  end

  def parse_float(_value), do: nil

  @doc "Whole non-negative seconds from a number or numeric string; anything else is nil."
  @spec parse_seconds(term()) :: non_neg_integer() | nil
  def parse_seconds(value) do
    case parse_float(value) do
      nil -> nil
      seconds -> trunc(seconds)
    end
  end

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_value), do: nil
end
