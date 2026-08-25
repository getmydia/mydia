defmodule Mydia.Streaming.CodecProfile do
  @moduledoc """
  The constraints attached to one codec a client claims.

  A client says "I decode hevc" with `DeviceProfile.video_codecs`, and says
  *which* hevc with a codec profile: the conditions here all have to hold for a
  stream in that codec to be handed over untouched.

  Matching the codec uses the same substring rule as the flat allowlists, so a
  profile written for `"hevc"` also covers the `"hevc (Main 10)"` shapes ffprobe
  display strings arrive in.

  Conditions are ANDed. An empty condition list means the codec is claimed
  unconditionally, which is exactly what the flat allowlists meant on their own
  and is why an old client that sends no codec profiles keeps working.
  """

  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Streaming.ProfileCondition

  @enforce_keys [:type, :codec]
  defstruct [:type, :codec, conditions: []]

  @type stream_type :: :video | :audio

  @type t :: %__MODULE__{
          type: stream_type(),
          codec: String.t(),
          conditions: [ProfileCondition.t()]
        }

  @max_conditions 32

  @doc """
  Builds a codec profile from a decoded JSON map.

  Returns `:error` when the type or codec is unusable, or when any condition
  fails to parse. A codec profile that silently lost a condition would claim
  more than the client meant, so a bad entry rejects the whole profile and the
  caller treats the payload as absent.
  """
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(%{} = map) do
    with {:ok, type} <- parse_type(Map.get(map, "type")),
         {:ok, codec} <- parse_codec(Map.get(map, "codec")),
         {:ok, conditions} <- parse_conditions(Map.get(map, "conditions", [])) do
      {:ok, %__MODULE__{type: type, codec: codec, conditions: conditions}}
    end
  end

  def from_map(_other), do: :error

  defp parse_type(type) when is_binary(type) do
    case type |> String.trim() |> String.downcase() do
      "video" -> {:ok, :video}
      "audio" -> {:ok, :audio}
      _ -> :error
    end
  end

  defp parse_type(_type), do: :error

  defp parse_codec(codec) when is_binary(codec) do
    normalized = codec |> String.trim() |> String.downcase()

    # An empty codec would substring-match every stream, turning one client's
    # constraint into a global one. Same trap the flat allowlists guard.
    if normalized == "" or String.length(normalized) > 64 do
      :error
    else
      {:ok, normalized}
    end
  end

  defp parse_codec(_codec), do: :error

  defp parse_conditions(conditions) when is_list(conditions) do
    if length(conditions) > @max_conditions do
      :error
    else
      Enum.reduce_while(conditions, {:ok, []}, fn entry, {:ok, acc} ->
        case ProfileCondition.from_map(entry) do
          {:ok, condition} -> {:cont, {:ok, [condition | acc]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
        :error -> :error
      end
    end
  end

  defp parse_conditions(_conditions), do: :error

  @doc "Whether this profile governs `codec` for streams of `type`."
  @spec applies?(t(), stream_type(), String.t() | nil) :: boolean()
  def applies?(%__MODULE__{type: type, codec: codec}, type, actual) when is_binary(actual) do
    actual |> String.downcase() |> String.contains?(codec)
  end

  def applies?(%__MODULE__{}, _type, _actual), do: false

  @doc """
  Whether `stream` satisfies every condition on this profile.
  """
  @spec satisfied?(t(), StreamInfo.t() | nil) :: boolean()
  def satisfied?(%__MODULE__{conditions: conditions}, stream) do
    Enum.all?(conditions, &ProfileCondition.satisfied?(&1, stream))
  end
end
