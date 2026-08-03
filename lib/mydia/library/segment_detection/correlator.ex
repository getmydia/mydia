defmodule Mydia.Library.SegmentDetection.Correlator do
  @moduledoc """
  Finds the longest run of near-identical audio between two fingerprint streams.

  A fingerprint stream is a list of unsigned 32-bit integers, one per audio
  frame. Two episodes of the same show share a run of near-identical frames
  wherever they share audio, which is exactly what the opening theme and the
  closing credits music are.

  ## Why not brute force

  Comparing every alignment offset is O(n^2). A 15-minute window is roughly
  7,200 frames, so a single pair of episodes would be about 50 million
  comparisons, multiplied again by the number of pairings and episodes. That is
  not viable here.

  Instead this module seeds and extends:

  1. Index stream B as `%{key => [positions]}`, keyed on the **top 16 bits** of
     each hash. Those are the most stable bits, so the key survives minor
     encoding differences while keeping the map small.
  2. Walk stream A. Each position looks up its key and votes for the alignment
     offset `i - j`.
  3. Verify only the highest-voted offsets with a single linear pass each,
     using a Hamming-distance tolerance per frame.

  That is O(n) lookups plus a small constant number of linear passes.

  All functions here are pure. No I/O, no database, no ffmpeg.
  """

  import Bitwise

  defmodule Match do
    @moduledoc "A verified run of matching frames, positioned in the first stream."

    @type t :: %__MODULE__{
            start_frame: non_neg_integer(),
            end_frame: non_neg_integer(),
            offset: integer(),
            length: pos_integer()
          }

    defstruct [:start_frame, :end_frame, :offset, :length]
  end

  # Maximum differing bits (of 32) for two frames to count as the same audio.
  @hamming_tolerance 6

  # Consecutive non-matching frames a run can absorb before it is considered
  # finished. Survives a brief dropout without merging two distinct runs.
  @gap_tolerance 3

  # How many of the highest-voted alignment offsets get a verification pass.
  @candidate_offsets 5

  # Popcount via four byte-sized lookups, built at compile time.
  @popcount_table (for i <- 0..255, into: %{} do
                     {i, Enum.count(Integer.digits(i, 2), &(&1 == 1))}
                   end)

  @doc """
  Returns the longest verified run of matching frames between `a` and `b`.

  Positions in the returned `Match` are indices into `a`. `offset` is the value
  such that `a[i]` aligns with `b[i - offset]`.

  ## Options

    * `:min_frames` - required. Runs shorter than this are rejected.
  """
  @spec best_match([non_neg_integer()], [non_neg_integer()], keyword()) ::
          {:ok, Match.t()} | :no_match
  def best_match(a, b, opts) do
    min_frames = Keyword.fetch!(opts, :min_frames)

    if a == [] or b == [] do
      :no_match
    else
      a_tuple = List.to_tuple(a)
      b_tuple = List.to_tuple(b)

      b
      |> build_index()
      |> vote_offsets(a)
      |> top_offsets()
      |> Enum.map(&verify_offset(a_tuple, b_tuple, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.length >= min_frames))
      |> case do
        [] -> :no_match
        matches -> {:ok, Enum.max_by(matches, & &1.length)}
      end
    end
  end

  # Index by the top 16 bits: stable enough to survive re-encoding, selective
  # enough to keep candidate lists short.
  defp build_index(stream) do
    stream
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {hash, position}, acc ->
      Map.update(acc, key(hash), [position], &[position | &1])
    end)
  end

  defp key(hash), do: hash >>> 16

  defp vote_offsets(index, a) do
    a
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {hash, i}, votes ->
      case Map.get(index, key(hash)) do
        nil ->
          votes

        positions ->
          Enum.reduce(positions, votes, fn j, acc ->
            Map.update(acc, i - j, 1, &(&1 + 1))
          end)
      end
    end)
  end

  defp top_offsets(votes) do
    votes
    |> Enum.sort_by(fn {_offset, count} -> count end, :desc)
    |> Enum.take(@candidate_offsets)
    |> Enum.map(fn {offset, _count} -> offset end)
  end

  # One linear pass over `a` at a fixed alignment, tracking the longest run of
  # frames whose Hamming distance is within tolerance.
  defp verify_offset(a_tuple, b_tuple, offset) do
    a_size = tuple_size(a_tuple)
    b_size = tuple_size(b_tuple)

    state = %{best: nil, run_start: nil, last_match: nil, gap: 0}

    0..(a_size - 1)
    |> Enum.reduce(state, fn i, acc ->
      j = i - offset

      if j >= 0 and j < b_size and
           similar?(elem(a_tuple, i), elem(b_tuple, j)) do
        %{acc | run_start: acc.run_start || i, last_match: i, gap: 0}
      else
        advance_gap(acc, offset)
      end
    end)
    |> close_run(offset)
    |> Map.fetch!(:best)
  end

  defp advance_gap(%{run_start: nil} = acc, _offset), do: acc

  defp advance_gap(acc, offset) do
    if acc.gap + 1 > @gap_tolerance do
      acc |> close_run(offset) |> Map.merge(%{run_start: nil, last_match: nil, gap: 0})
    else
      %{acc | gap: acc.gap + 1}
    end
  end

  defp close_run(%{run_start: nil} = acc, _offset), do: acc

  defp close_run(acc, offset) do
    match = %Match{
      start_frame: acc.run_start,
      end_frame: acc.last_match,
      offset: offset,
      length: acc.last_match - acc.run_start + 1
    }

    if is_nil(acc.best) or match.length > acc.best.length do
      %{acc | best: match}
    else
      acc
    end
  end

  defp similar?(x, y), do: popcount(bxor(x, y)) <= @hamming_tolerance

  defp popcount(n) do
    @popcount_table[n &&& 0xFF] +
      @popcount_table[n >>> 8 &&& 0xFF] +
      @popcount_table[n >>> 16 &&& 0xFF] +
      @popcount_table[n >>> 24 &&& 0xFF]
  end
end
