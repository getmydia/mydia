defmodule Mydia.Streaming.SegmentPlan do
  @moduledoc """
  The complete segment layout of a streaming session, computed from the media
  duration before FFmpeg has produced anything.

  This is the contract the server publishes to the player. Every segment the
  playlist names is addressable from the moment the session starts; whether the
  bytes exist yet is `Mydia.Streaming.TranscodeWindow`'s problem, not the
  playlist's.

  Declared durations are uniform. In transcode mode that is exact, because
  `-force_key_frames` puts keyframes on the same grid. In copy mode FFmpeg cuts
  at the first source keyframe at or after each boundary, so real durations vary
  by up to one GOP while these stay uniform. That drift is bounded and does not
  accumulate (each cut is measured from the grid, not from the previous cut),
  and `-copyts` keeps segment timestamps absolute, so the player's clock stays
  correct even where a boundary does not.
  """

  @enforce_keys [:duration, :segment_seconds, :count]
  defstruct [:duration, :segment_seconds, :count]

  @type t :: %__MODULE__{
          duration: float(),
          segment_seconds: pos_integer(),
          count: pos_integer()
        }

  @default_segment_seconds 4

  @segment_name_pattern ~r/^segment_(\d{5})\.ts\z/

  @doc """
  The segment length every session uses, in seconds.

  Matches the transcoder's `-hls_time`. Read it from here rather than repeating
  the literal: the playlist and the FFmpeg arguments must never disagree.
  """
  @spec default_segment_seconds() :: pos_integer()
  def default_segment_seconds, do: @default_segment_seconds

  @doc """
  Builds a plan, or returns `:error` when the duration is unknown or unusable.

  `:error` is an ordinary answer, not a failure: a file whose inline probe
  budget was exceeded has no duration, and its session falls back to the
  windowed playlist.
  """
  @spec build(number() | nil, pos_integer()) :: {:ok, t()} | :error
  def build(duration, segment_seconds \\ @default_segment_seconds)

  def build(duration, segment_seconds)
      when is_number(duration) and duration > 0 and is_integer(segment_seconds) and
             segment_seconds > 0 do
    {:ok,
     %__MODULE__{
       duration: duration / 1,
       segment_seconds: segment_seconds,
       count: ceil(duration / segment_seconds)
     }}
  end

  def build(_duration, _segment_seconds), do: :error

  @doc "The real media time at which segment `index` begins."
  @spec start_time(t(), non_neg_integer()) :: float()
  def start_time(%__MODULE__{segment_seconds: seconds}, index), do: index * seconds / 1

  @doc """
  The segment containing `seconds`, clamped into the plan at both ends.

  Clamping rather than raising: a corrupt progress row can ask to resume past
  the end, and landing on the last segment is a better answer than a crash.
  """
  @spec index_for_time(t(), number()) :: non_neg_integer()
  def index_for_time(%__MODULE__{segment_seconds: seconds, count: count}, time) do
    time
    |> max(0)
    |> Kernel./(seconds)
    |> trunc()
    |> min(count - 1)
  end

  @doc "The declared length of segment `index`, which is short only for the last."
  @spec duration_of(t(), non_neg_integer()) :: float()
  def duration_of(%__MODULE__{} = plan, index) do
    if index == plan.count - 1 do
      plan.duration - index * plan.segment_seconds
    else
      plan.segment_seconds / 1
    end
  end

  @doc """
  The on-disk filename for a segment index.

  Fixed five-digit width so the name is a pure function of the index and FFmpeg's
  `-hls_segment_filename` pattern can produce it directly. Five digits covers 55
  hours at four seconds.
  """
  @spec segment_name(non_neg_integer()) :: String.t()
  def segment_name(index) do
    "segment_" <> String.pad_leading(Integer.to_string(index), 5, "0") <> ".ts"
  end

  @doc """
  Reads a segment index back out of a filename.

  Returns `:error` for anything that is not one, which the controller relies on:
  it feeds every requested path through here, subtitle tracks included.
  """
  @spec index_from_name(String.t()) :: {:ok, non_neg_integer()} | :error
  def index_from_name(name) when is_binary(name) do
    case Regex.run(@segment_name_pattern, name) do
      [_, digits] -> {:ok, String.to_integer(digits)}
      nil -> :error
    end
  end

  def index_from_name(_name), do: :error

  @doc "Renders the plan as a complete, terminated VOD media playlist."
  @spec playlist(t()) :: String.t()
  def playlist(%__MODULE__{} = plan) do
    header = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:#{plan.segment_seconds}
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-PLAYLIST-TYPE:VOD
    """

    entries =
      Enum.map_join(0..(plan.count - 1), fn index ->
        seconds = :erlang.float_to_binary(duration_of(plan, index), decimals: 6)
        "#EXTINF:#{seconds},\n#{segment_name(index)}\n"
      end)

    header <> entries <> "#EXT-X-ENDLIST\n"
  end
end
