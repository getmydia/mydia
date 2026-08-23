defmodule Mydia.Streaming.DeviceProfile do
  @moduledoc """
  What a client can decode, as four allowlists.

  A profile arrives per request in the `X-Mydia-Device-Profile` header and
  parameterizes `Mydia.Streaming.Compatibility`. It is deliberately not
  persisted: a stored profile goes stale silently when the viewer changes OS,
  display, or hardware decode availability, which is the failure this replaces.

  ## Matching

  Containers and HDR formats match exactly, because those values arrive
  normalized. Video and audio codecs match by substring, because ffprobe emits
  display strings like "H.264 (Main)" and "AAC 5.1" and the column stores them
  verbatim.

  Entries are plain strings and are never converted to atoms. The payload is
  attacker-controlled and its contents read exactly like atom names, which is
  precisely the shape that invites an unsafe `String.to_atom/1`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @max_entries 64
  @max_entry_length 64

  @type t :: %__MODULE__{
          containers: [String.t()],
          video_codecs: [String.t()],
          audio_codecs: [String.t()],
          hdr_formats: [String.t()]
        }

  @primary_key false
  embedded_schema do
    field(:containers, {:array, :string}, default: [])
    field(:video_codecs, {:array, :string}, default: [])
    field(:audio_codecs, {:array, :string}, default: [])
    field(:hdr_formats, {:array, :string}, default: [])
  end

  @doc """
  The lists `Compatibility` hardcoded before profiles existed.

  Moved verbatim so that "no profile supplied" is provably identical to the
  behavior that shipped before this module.
  """
  @spec browser_default() :: t()
  def browser_default do
    %__MODULE__{
      containers: ["mp4", "webm", "m4v"],
      video_codecs: ["h264", "h.264", "avc", "avc1", "vp9", "vp09", "av1", "av01"],
      audio_codecs: ["aac", "mp3", "opus", "vorbis"],
      hdr_formats: []
    }
  end

  @doc """
  Casts decoded JSON into a profile.

  Returns `:error` for anything malformed or over the caps. Callers treat
  `:error` as an absent profile rather than as a request failure.
  """
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(map) when is_map(map) do
    # cast/3 treats an explicit `nil` value as "set this field to nil", which
    # would stomp the embedded schema's `default: []`. Omit absent keys
    # entirely so a missing list falls through to that default instead.
    params =
      %{
        "containers" => Map.get(map, "containers"),
        "video_codecs" => Map.get(map, "videoCodecs"),
        "audio_codecs" => Map.get(map, "audioCodecs"),
        "hdr_formats" => Map.get(map, "hdrFormats")
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    changeset =
      %__MODULE__{}
      |> cast(params, [:containers, :video_codecs, :audio_codecs, :hdr_formats])
      |> validate_list(:containers)
      |> validate_list(:video_codecs)
      |> validate_list(:audio_codecs)
      |> validate_list(:hdr_formats)
      |> downcase_list(:containers)
      |> downcase_list(:video_codecs)
      |> downcase_list(:audio_codecs)
      |> downcase_list(:hdr_formats)

    case apply_action(changeset, :insert) do
      {:ok, profile} -> {:ok, profile}
      {:error, _changeset} -> :error
    end
  end

  def from_map(_other), do: :error

  @doc "Whether the container is listed. Exact match, case-insensitive."
  @spec container_allowed?(t(), String.t() | nil) :: boolean()
  def container_allowed?(%__MODULE__{containers: list}, container) when is_binary(container) do
    String.downcase(container) in list
  end

  def container_allowed?(%__MODULE__{}, _container), do: false

  @doc "Whether the video codec is listed. Substring match, case-insensitive."
  @spec video_codec_allowed?(t(), String.t() | nil) :: boolean()
  def video_codec_allowed?(%__MODULE__{video_codecs: list}, codec) when is_binary(codec) do
    contains_any?(list, codec)
  end

  def video_codec_allowed?(%__MODULE__{}, _codec), do: false

  @doc """
  Whether the audio codec is listed, or absent.

  A video with no audio track is playable, so `nil` is allowed. This mirrors
  the `audio_compatible_or_absent?/1` behavior `Compatibility` had before
  profiles existed.
  """
  @spec audio_codec_allowed_or_absent?(t(), String.t() | nil) :: boolean()
  def audio_codec_allowed_or_absent?(%__MODULE__{}, nil), do: true

  def audio_codec_allowed_or_absent?(%__MODULE__{audio_codecs: list}, codec)
      when is_binary(codec) do
    contains_any?(list, codec)
  end

  def audio_codec_allowed_or_absent?(%__MODULE__{}, _codec), do: false

  @doc """
  Whether the HDR format is listed, or absent.

  Most files carry no HDR format, and those are unconstrained. A file that does
  carry one must have it listed, which is the rule that reaches formats a client
  cannot decode even though it handles the underlying video codec.
  """
  @spec hdr_allowed_or_absent?(t(), String.t() | nil) :: boolean()
  def hdr_allowed_or_absent?(%__MODULE__{}, nil), do: true

  def hdr_allowed_or_absent?(%__MODULE__{hdr_formats: list}, hdr) when is_binary(hdr) do
    String.downcase(hdr) in list
  end

  def hdr_allowed_or_absent?(%__MODULE__{}, _hdr), do: false

  defp contains_any?(list, value) do
    normalized = String.downcase(value)
    Enum.any?(list, fn entry -> String.contains?(normalized, entry) end)
  end

  defp validate_list(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      entries when is_list(entries) ->
        cond do
          length(entries) > @max_entries ->
            add_error(changeset, field, "too many entries")

          Enum.any?(entries, &(String.length(&1) > @max_entry_length)) ->
            add_error(changeset, field, "entry too long")

          true ->
            changeset
        end
    end
  end

  defp downcase_list(changeset, field) do
    case get_change(changeset, field) do
      nil -> changeset
      entries -> put_change(changeset, field, Enum.map(entries, &String.downcase/1))
    end
  end
end
