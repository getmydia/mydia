defmodule Mydia.Streaming.TranscodeWindow do
  @moduledoc """
  Where the encoder currently is, and what to do about a segment request.

  The full playlist promises every segment in the file. This decides, for one
  requested segment, whether the bytes are already there (`:serve`), whether the
  running encoder will reach them soon enough to be worth waiting for
  (`:wait`), or whether the encoder has to be moved (`{:relocate, index}`).

  `wait_ahead_segments/0` is the server-side successor to the player's old
  `kSeekRestartTolerance`. It exists for the same reason: early in a session
  only a few seconds have been encoded, and without a tolerance every small
  forward skip would pay for a relocation. Deciding it here rather than in the
  client is the point of the whole change, because only the server knows how far
  the encoder has actually got.

  Pure and free of process state so the decision can be tested exhaustively,
  the same way the player's `shouldRestartForSeek` was.
  """

  @wait_ahead_segments 3

  defstruct available: MapSet.new(),
            first_index: 0,
            last_ready_index: -1,
            running?: true

  @type t :: %__MODULE__{
          available: MapSet.t(non_neg_integer()),
          first_index: non_neg_integer(),
          last_ready_index: integer(),
          running?: boolean()
        }

  @type decision :: :serve | :wait | {:relocate, non_neg_integer()}

  @doc "How far past the encoder's last finished segment to wait rather than relocate."
  @spec wait_ahead_segments() :: pos_integer()
  def wait_ahead_segments, do: @wait_ahead_segments

  @doc "A window whose encoder has just been started at `first_index`."
  @spec new(non_neg_integer()) :: t()
  def new(first_index) do
    %__MODULE__{first_index: first_index, last_ready_index: first_index - 1, running?: true}
  end

  @doc """
  What to do about a request for `index`.

  Order matters. Disk is checked before anything else, so a segment left behind
  by an earlier window is served even when the encoder has moved on and even
  when it has stopped entirely.
  """
  @spec decide(t(), non_neg_integer()) :: decision()
  def decide(%__MODULE__{} = window, index) do
    cond do
      MapSet.member?(window.available, index) -> :serve
      not window.running? -> {:relocate, index}
      index < window.first_index -> {:relocate, index}
      index <= window.last_ready_index + @wait_ahead_segments -> :wait
      true -> {:relocate, index}
    end
  end

  @doc "Records segments the encoder has finished writing."
  @spec mark_ready(t(), [non_neg_integer()]) :: t()
  def mark_ready(%__MODULE__{} = window, indices) do
    %{
      window
      | available: Enum.into(indices, window.available),
        last_ready_index: Enum.reduce(indices, window.last_ready_index, &max/2)
    }
  end

  @doc """
  Moves the encoder to `index`.

  `available` is deliberately untouched: the segments an earlier window wrote
  stay on disk, which is what makes scrubbing back into a watched region free.
  """
  @spec relocate(t(), non_neg_integer()) :: t()
  def relocate(%__MODULE__{} = window, index) do
    %{window | first_index: index, last_ready_index: index - 1, running?: true}
  end

  @doc "Records that the encoder is no longer running, without losing the disk state."
  @spec stopped(t()) :: t()
  def stopped(%__MODULE__{} = window), do: %{window | running?: false}
end
