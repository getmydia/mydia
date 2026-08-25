defmodule Mydia.Streaming.DeviceProfile do
  @moduledoc """
  What a client can decode: four allowlists, plus the constraints on them.

  A profile arrives per request in the `X-Mydia-Device-Profile` header and
  parameterizes `Mydia.Streaming.Compatibility`. It is deliberately not
  persisted: a stored profile goes stale silently when the viewer changes OS,
  display, or hardware decode availability, which is the failure this replaces.

  ## Why codec names alone are not enough

  The allowlists answer "which codecs", and that turned out to be the wrong
  question on its own. A tablet whose MediaCodec decoder opens HEVC Main and
  refuses HEVC Main 10 still advertised `hevc`, because the native client reads
  libmpv's `decoder-list` — a libavcodec *build* list, blind to profile and bit
  depth. The server direct-played a 10-bit stream at it and playback died on
  "Could not open codec." with no recoverable path.

  `codec_profiles` carries the rest: per-codec `Mydia.Streaming.ProfileCondition`
  sets over bit depth, profile, level, resolution, frame rate and channel count,
  evaluated against the file's real per-stream metadata. A codec with no
  conditions is claimed unconditionally, so a client that sends none behaves
  exactly as it did before conditions existed.

  ## Matching

  Containers and HDR formats match exactly, because those values arrive
  normalized. Video and audio codecs match by substring, because ffprobe emits
  display strings like "H.264 (Main)" and "AAC 5.1" and the column stores them
  verbatim.

  Entries are plain strings and are never converted to atoms. The payload is
  attacker-controlled and its contents read exactly like atom names, which is
  precisely the shape that invites an unsafe `String.to_atom/1`.

  ## HDR is parsed but not enforced

  `hdr_formats` is accepted, capped, and downcased like the other lists, so the
  wire format is stable, but `Mydia.Streaming.Compatibility` does not consult
  it yet. See the comment above `codecs_playable?/3` there for why.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Streaming.CodecProfile

  @max_entries 64
  @max_entry_length 64
  @max_encoded_bytes 4096

  @type t :: %__MODULE__{
          containers: [String.t()],
          video_codecs: [String.t()],
          audio_codecs: [String.t()],
          hdr_formats: [String.t()],
          codec_profiles: [CodecProfile.t()]
        }

  @primary_key false
  embedded_schema do
    field(:containers, {:array, :string}, default: [])
    field(:video_codecs, {:array, :string}, default: [])
    field(:audio_codecs, {:array, :string}, default: [])
    field(:hdr_formats, {:array, :string}, default: [])

    # Parsed by hand rather than cast, because these are nested structs and the
    # "one bad entry rejects the payload" rule below is stricter than a
    # changeset's per-field errors express. Virtual so the embedded schema stays
    # the flat, castable shape the four allowlists need.
    field(:codec_profiles, :any, virtual: true, default: [])
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
      # `empty_values: []` turns off cast/3's default behavior of silently
      # dropping "" entries from array fields (built for HTML forms, where a
      # blank multi-select submits ""). That default would swallow an empty
      # codec entry into the field's default `[]` before validate_list/2
      # ever saw it, so the malformed-entry check below would never fire.
      |> cast(params, [:containers, :video_codecs, :audio_codecs, :hdr_formats], empty_values: [])
      |> validate_list(:containers)
      |> validate_list(:video_codecs)
      |> validate_list(:audio_codecs)
      |> validate_list(:hdr_formats)
      |> downcase_list(:containers)
      |> downcase_list(:video_codecs)
      |> downcase_list(:audio_codecs)
      |> downcase_list(:hdr_formats)

    with {:ok, profile} <- apply_action(changeset, :insert),
         {:ok, codec_profiles} <- parse_codec_profiles(Map.get(map, "codecProfiles", [])) do
      {:ok, %{profile | codec_profiles: codec_profiles}}
    else
      _ -> :error
    end
  end

  def from_map(_other), do: :error

  # A malformed codec profile rejects the whole payload rather than being
  # dropped. A dropped constraint is indistinguishable from a client that never
  # had one, and that difference is the direction that widens direct play.
  defp parse_codec_profiles(entries) when is_list(entries) do
    if length(entries) > @max_entries do
      :error
    else
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        case CodecProfile.from_map(entry) do
          {:ok, codec_profile} -> {:cont, {:ok, [codec_profile | acc]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
        :error -> :error
      end
    end
  end

  defp parse_codec_profiles(_entries), do: :error

  @doc """
  Decodes a raw device profile header value into a profile.

  Shared by every transport that can carry a device profile: HTTP passes the
  `X-Mydia-Device-Profile` header value through `MydiaWeb.Plugs.DeviceProfile`,
  and p2p passes the `GraphQLRequest.device_profile` field through
  `Mydia.P2p.Server` unchanged, since p2p has no headers of its own. Keeping
  the decode chain here means the 4 KB cap, base64url decode, JSON parse and
  validation are applied identically everywhere instead of drifting between
  two copies.

  Applies the 4 KB cap on the raw value before attempting to decode it at all,
  so an oversized payload is never base64-decoded or parsed. Returns `nil` for
  a `nil` input or anything malformed, over-cap, non-base64, non-JSON, or
  non-object, mirroring `from_map/1`'s "treat as absent, not as an error"
  contract.
  """
  @spec decode_header(String.t() | nil) :: t() | nil
  def decode_header(nil), do: nil

  def decode_header(value) when is_binary(value) do
    if byte_size(value) > @max_encoded_bytes do
      nil
    else
      with {:ok, json} <- Base.url_decode64(value, padding: false),
           {:ok, map} <- Jason.decode(json),
           {:ok, profile} <- from_map(map) do
        profile
      else
        _ -> nil
      end
    end
  end

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
  Whether `stream` satisfies every codec profile this client attached to `codec`.

  A codec the client attached no conditions to is unconstrained, which is what
  the flat allowlist meant on its own — so a client that sends no codec profiles
  behaves exactly as it did before conditions existed.

  Note this answers only the *conditions*. Whether the codec is claimed at all
  is still `video_codec_allowed?/2` and `audio_codec_allowed_or_absent?/2`;
  both have to hold.
  """
  @spec codec_conditions_met?(
          t(),
          CodecProfile.stream_type(),
          String.t() | nil,
          StreamInfo.t() | nil
        ) ::
          boolean()
  def codec_conditions_met?(%__MODULE__{codec_profiles: profiles}, type, codec, stream)
      when is_list(profiles) do
    profiles
    |> Enum.filter(&CodecProfile.applies?(&1, type, codec))
    |> Enum.all?(&CodecProfile.satisfied?(&1, stream))
  end

  def codec_conditions_met?(%__MODULE__{}, _type, _codec, _stream), do: true

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

          Enum.any?(entries, &(&1 == "")) ->
            # String.contains?(anything, "") is always true, so an empty entry
            # would make contains_any?/2 match every codec instead of none.
            # Reject it here, with the other caps, rather than filtering it
            # out at match time.
            add_error(changeset, field, "entry cannot be empty")

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
