defmodule Mydia.Library.SegmentDetection do
  @moduledoc """
  Locates intro and credits segments across a season of TV episodes.

  ## Why a season is the unit

  An opening theme is only recognisable as one because it *recurs*. A single
  episode in isolation gives nothing to compare against, so detection is
  inherently season-scoped even though results are stored per file.

  There is no `seasons` table: a season is the tuple
  `(media_item_id, season_number)` derived from `episodes`.

  ## Order of operations

  1. Chapter markers, when the container has them. Near-free and exact.
  2. Audio fingerprint correlation for whatever chapters did not resolve.
  3. Black-frame refinement of the credits end.

  Results below the acceptance bar are recorded as `not_found`, which is an
  answer rather than a failure and therefore consumes no retry attempts.

  ## Strictly additive

  This is background work. Nothing here blocks scanning, import, or playback,
  and every per-file failure is recorded on the row instead of raised, so one
  unreadable file cannot abort the rest of the season.
  """

  import Ecto.Query

  require Logger

  alias Mydia.Library.MediaFile
  alias Mydia.Library.MediaSegment
  alias Mydia.Library.SegmentDetection.Boundary
  alias Mydia.Library.SegmentDetection.Chapters
  alias Mydia.Library.SegmentDetection.Correlator
  alias Mydia.Library.SegmentDetection.Fingerprint
  alias Mydia.Library.SegmentDetection.FingerprintCache
  alias Mydia.Media.Episode
  alias Mydia.Repo

  # Search windows, in seconds and as a fraction of runtime. An intro is almost
  # always in the first stretch, but a long cold open can push it later.
  @intro_window_max_s 15 * 60
  @intro_window_fraction 0.4
  @credits_window_max_s 10 * 60
  @credits_window_fraction 0.3

  # Minimum length for a run to count as a theme. Measured intros run 40 to 90
  # seconds, so these floors are deliberately conservative.
  @min_intro_s 15
  @min_credits_s 20

  # Correlation partners per target, and the minimum that must agree.
  @partner_count 5
  @min_agreeing 2

  # Two matches agree when their starts land within this of each other. Real
  # detections cluster within a frame or two (~124ms); this is deliberately
  # loose enough to absorb that while still rejecting a spurious match
  # elsewhere in the episode.
  @agree_tolerance_ms 2_000

  @max_attempts 3

  @segment_types ~w(intro credits)

  @doc """
  Analyses one season and writes its segments.

  Always returns `:ok`. Per-file failures are recorded on the row rather than
  raised, so one unreadable file cannot abort the rest of the season.
  """
  @spec analyze_season(binary(), integer()) :: :ok
  def analyze_season(media_item_id, season_number) do
    files = season_files(media_item_id, season_number)

    # Both search windows are computed from the runtime, which `FileAnalysis`
    # supplies. A file without one is not a failure, it is not ready: it stays
    # `pending`, spends no attempt, and is picked up on a later tick.
    ready = Enum.filter(files, &duration_known?/1)
    targets = Enum.filter(ready, &pending?/1)

    cond do
      targets == [] ->
        :ok

      length(files) < 2 ->
        # Nothing to correlate against, ever. Chapters may still resolve it.
        Enum.each(targets, &analyze_chapters_only/1)
        :ok

      length(ready) < 2 ->
        # The season is big enough, but its other files have no runtime yet.
        # Waiting is the right answer here; `not_found` would be terminal.
        :ok

      true ->
        Enum.each(targets, &analyze_file(&1, ready))
        :ok
    end
  end

  @doc """
  Combines per-partner matches into a single result.

  Requires `#{@min_agreeing}` matches **that agree with each other**. Matches
  are first reduced to the largest cluster whose starts fall within
  `#{@agree_tolerance_ms}` ms; medians of start and end are then taken
  independently over that cluster. Confidence is the share of attempted
  pairings that agreed.

  Clustering before counting is what makes the minimum case safe. Counting
  every match instead would measure "partners that found any run" rather than
  "partners that agreed on the same run", and the median of two values is
  their midpoint, so a correct match at 2:00 paired with a spurious one at
  15:00 would ship a segment at 8:30 at exactly the confidence the exposure
  floor admits. Agreement is all or nothing on real media, so clustering costs
  nothing in the common case and only bites when a spurious run appears.
  """
  @spec consensus([%{start_ms: integer(), end_ms: integer()}], pos_integer()) ::
          {:ok, %{start_ms: integer(), end_ms: integer(), confidence: float()}} | :no_consensus
  def consensus(matches, attempted) when is_list(matches) and is_integer(attempted) do
    agreeing = largest_cluster(matches)

    if attempted > 0 and length(agreeing) >= @min_agreeing do
      {:ok,
       %{
         start_ms: median(Enum.map(agreeing, & &1.start_ms)),
         end_ms: median(Enum.map(agreeing, & &1.end_ms)),
         confidence: length(agreeing) / attempted
       }}
    else
      :no_consensus
    end
  end

  def consensus(_matches, _attempted), do: :no_consensus

  @doc """
  Picks correlation partners spread across the season.

  Deliberately not the nearest neighbours: a two-part opener or a recap-heavy
  premiere sits next to exactly the episodes that would otherwise be chosen.
  """
  @spec partners([term()], term(), pos_integer()) :: [term()]
  def partners(files, target, count) do
    case Enum.reject(files, &(&1 == target)) do
      [] ->
        []

      others ->
        total = length(others)

        if total <= count do
          others
        else
          step = total / count

          0..(count - 1)
          |> Enum.map(fn i -> Enum.at(others, trunc(i * step)) end)
          |> Enum.uniq()
        end
    end
  end

  @doc """
  Clears a season's segments and returns its files to `pending`.

  Cached fingerprints are kept, so a re-analysis does not re-decode audio.
  """
  @spec reset_season(binary(), integer()) :: :ok
  def reset_season(media_item_id, season_number) do
    file_ids = media_item_id |> season_files(season_number) |> Enum.map(& &1.id)

    Repo.delete_all(from(s in MediaSegment, where: s.media_file_id in ^file_ids))

    Repo.update_all(
      from(mf in MediaFile, where: mf.id in ^file_ids),
      set: [
        segment_analysis_state: "pending",
        segment_analysis_attempts: 0,
        last_segment_analysis_error: nil,
        segments_analyzed_at: nil
      ]
    )

    :ok
  end

  @doc """
  Summarises a season for the admin UI.

  `:state` is derived: `:detected` when every file resolved with at least one
  segment, `:partial` when some did, and otherwise the dominant file state.
  """
  @spec season_status(binary(), integer()) :: %{
          state: atom(),
          segments: %{optional(String.t()) => MediaSegment.t()},
          source: String.t() | nil
        }
  def season_status(media_item_id, season_number) do
    files =
      media_item_id
      |> season_files(season_number)
      |> Repo.preload(:segments)

    with_segments = Enum.filter(files, &(&1.segments != []))
    sample = List.first(with_segments)

    %{
      state: derive_state(files, with_segments),
      segments: sample_segments(sample),
      source: sample_source(sample)
    }
  end

  defp derive_state(files, with_segments) do
    cond do
      files == [] -> :pending
      Enum.any?(files, &(&1.segment_analysis_state == "failed")) -> :failed
      length(with_segments) == length(files) -> :detected
      with_segments != [] -> :partial
      Enum.all?(files, &(&1.segment_analysis_state == "not_found")) -> :not_found
      true -> :pending
    end
  end

  defp sample_segments(nil), do: %{}
  defp sample_segments(file), do: Map.new(file.segments, &{&1.type, &1})

  defp sample_source(nil), do: nil
  defp sample_source(file), do: file.segments |> List.first() |> Map.fetch!(:source)

  # -- season loading -------------------------------------------------------

  defp season_files(media_item_id, season_number) do
    Repo.all(
      from(mf in MediaFile,
        join: e in Episode,
        on: e.id == mf.episode_id,
        where:
          e.media_item_id == ^media_item_id and e.season_number == ^season_number and
            is_nil(mf.trashed_at),
        order_by: [asc: e.episode_number],
        preload: :library_path
      )
    )
  end

  defp pending?(%MediaFile{segment_analysis_state: "pending", segment_analysis_attempts: n}),
    do: n < @max_attempts

  defp pending?(_file), do: false

  defp duration_known?(file), do: match?({:ok, _duration}, duration_seconds(file))

  # -- per-file analysis ----------------------------------------------------

  defp analyze_chapters_only(file) do
    case chapter_segments(file) do
      found when found != %{} ->
        write_chapter_segments(file, found)
        mark(file, "detected")

      _none ->
        mark(file, "not_found")
    end
  end

  defp analyze_file(file, files) do
    chapters = chapter_segments(file)
    write_chapter_segments(file, chapters)

    # Resolution is per segment type: a file whose chapters name an opening but
    # not an ending still needs its credits window fingerprinted.
    remaining = Enum.reject(@segment_types, &Map.has_key?(chapters, &1))

    case detect_by_fingerprint(file, files, remaining) do
      {:ok, detected_any?} ->
        mark(file, if(detected_any? or chapters != %{}, do: "detected", else: "not_found"))

      {:error, reason} ->
        mark_failure(file, reason)
    end
  end

  # A chapter read that fails is not a detection failure. ffprobe may be
  # missing, or the container may carry no chapters at all, and fingerprinting
  # can still answer, so the failure degrades to "no chapters".
  defp chapter_segments(file) do
    with path when is_binary(path) <- MediaFile.absolute_path(file),
         {:ok, found} <- Chapters.detect(path) do
      found
    else
      _no_chapters -> %{}
    end
  end

  defp write_chapter_segments(file, chapters) do
    Enum.each(chapters, fn {type, {start_ms, end_ms}} ->
      upsert_segment(file, type, start_ms, end_ms, "chapters", 1.0)
    end)
  end

  defp detect_by_fingerprint(_file, _files, []), do: {:ok, false}

  defp detect_by_fingerprint(file, files, types) do
    Enum.reduce_while(types, {:ok, false}, fn type, {:ok, acc} ->
      case detect_type(file, files, type) do
        {:ok, true} -> {:cont, {:ok, true}}
        {:ok, false} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp detect_type(file, files, type) do
    case fingerprint_for(file, type) do
      {:ok, target_fp} -> correlate(file, files, type, target_fp)
      {:error, reason} -> {:error, reason}
    end
  end

  defp correlate(file, files, type, target_fp) do
    candidates = partners(files, file, @partner_count)

    matches =
      Enum.flat_map(candidates, fn partner ->
        case fingerprint_for(partner, type) do
          {:ok, partner_fp} -> match_pair(target_fp, partner_fp, type)
          {:error, _reason} -> []
        end
      end)

    case consensus(matches, max(length(candidates), 1)) do
      {:ok, result} ->
        end_ms = maybe_refine(file, type, result.start_ms, result.end_ms)
        upsert_segment(file, type, result.start_ms, end_ms, "fingerprint", result.confidence)
        {:ok, true}

      :no_consensus ->
        {:ok, false}
    end
  end

  defp match_pair(target_fp, partner_fp, type) do
    min_frames = round(min_seconds(type) * 1000 / target_fp.frame_ms)

    case Correlator.best_match(target_fp.hashes, partner_fp.hashes, min_frames: min_frames) do
      {:ok, match} ->
        # Frame positions are relative to the window, so the window's own start
        # is added back. For the intro window that is zero; for credits it is
        # not. `end_frame` is inclusive, hence the + 1.
        offset_ms = target_fp.window_start_ms

        [
          %{
            start_ms: offset_ms + round(match.start_frame * target_fp.frame_ms),
            end_ms: offset_ms + round((match.end_frame + 1) * target_fp.frame_ms)
          }
        ]

      :no_match ->
        []
    end
  end

  defp min_seconds("intro"), do: @min_intro_s
  defp min_seconds("credits"), do: @min_credits_s

  defp maybe_refine(file, "credits", start_ms, end_ms) do
    case MediaFile.absolute_path(file) do
      nil ->
        end_ms

      path ->
        refined = Boundary.refine_end(path, end_ms)

        # refine_end/2 snaps to the last black transition inside a window that
        # extends both sides of end_ms, so it can move the end EARLIER as well
        # as later. At the minimum credits run of 20s, a full backward snap
        # puts the end at or before the start. MediaSegment.changeset/2 rejects
        # that, and the caller would still record the type as detected, leaving
        # a file marked detected with nothing persisted. An unrefined end beats
        # a segment that cannot be written.
        if refined > start_ms, do: refined, else: end_ms
    end
  end

  defp maybe_refine(_file, _type, _start_ms, end_ms), do: end_ms

  # -- fingerprints ---------------------------------------------------------

  defp fingerprint_for(file, type) do
    with {:ok, duration} <- duration_seconds(file),
         path when is_binary(path) <- MediaFile.absolute_path(file) do
      {start_s, length_s} = window(type, duration)
      load_or_compute(file, type, path, start_s, length_s)
    else
      nil -> {:error, :path_not_resolved}
      :error -> {:error, :duration_unknown}
    end
  end

  defp load_or_compute(file, type, path, start_s, length_s) do
    case FingerprintCache.fetch(file, type) do
      {:ok, result} ->
        {:ok, put_window(result, start_s)}

      :miss ->
        case Fingerprint.fingerprint(path, start_s, length_s) do
          {:ok, result} ->
            FingerprintCache.put(file, type, result)
            {:ok, put_window(result, start_s)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp put_window(result, start_s), do: %{result | window_start_ms: max(round(start_s * 1000), 0)}

  defp window("intro", duration) do
    {0, min(@intro_window_max_s, duration * @intro_window_fraction)}
  end

  defp window("credits", duration) do
    length_s = min(@credits_window_max_s, duration * @credits_window_fraction)
    {max(duration - length_s, 0), length_s}
  end

  defp duration_seconds(%MediaFile{metadata: %{duration: duration}})
       when is_number(duration) and duration > 0,
       do: {:ok, duration}

  defp duration_seconds(_file), do: :error

  # -- persistence ----------------------------------------------------------

  defp upsert_segment(file, type, start_ms, end_ms, source, confidence) do
    attrs = %{
      media_file_id: file.id,
      type: type,
      start_ms: start_ms,
      end_ms: end_ms,
      source: source,
      confidence: confidence
    }

    result =
      case Repo.get_by(MediaSegment, media_file_id: file.id, type: type) do
        nil -> %MediaSegment{} |> MediaSegment.changeset(attrs) |> Repo.insert()
        segment -> segment |> MediaSegment.changeset(attrs) |> Repo.update()
      end

    case result do
      {:ok, segment} ->
        segment

      {:error, changeset} ->
        Logger.warning("Rejected detected segment",
          file_id: file.id,
          type: type,
          errors: inspect(changeset.errors)
        )

        nil
    end
  end

  # State writes are guarded on the row still being `pending`, so a concurrent
  # operator re-analysis or a second worker cannot clobber a fresher result.
  defp mark(file, state) do
    Repo.update_all(
      from(mf in MediaFile, where: mf.id == ^file.id and mf.segment_analysis_state == "pending"),
      set: [
        segment_analysis_state: state,
        segments_analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        last_segment_analysis_error: nil
      ]
    )

    :ok
  end

  defp mark_failure(file, reason) do
    attempts = file.segment_analysis_attempts + 1
    state = if attempts >= @max_attempts, do: "failed", else: "pending"

    # Guarded on the attempt count as well as the state, so the write is a
    # compare-and-set. Deriving `attempts` from the in-memory struct means two
    # writers holding the same stale count would both store the same value, and
    # the file would quietly get more than @max_attempts tries. Matching on the
    # value we read makes the second write a no-op instead.
    Repo.update_all(
      from(mf in MediaFile,
        where:
          mf.id == ^file.id and mf.segment_analysis_state == "pending" and
            mf.segment_analysis_attempts == ^file.segment_analysis_attempts
      ),
      set: [
        segment_analysis_state: state,
        segment_analysis_attempts: attempts,
        last_segment_analysis_error: inspect(reason)
      ]
    )

    Logger.warning("Segment detection failed",
      file_id: file.id,
      attempts: attempts,
      reason: inspect(reason)
    )

    :ok
  end

  # -- consensus helpers ----------------------------------------------------

  # Largest group whose starts agree within tolerance. O(n^2) over at most
  # @partner_count matches, so the naive form is fine.
  defp largest_cluster([]), do: []

  defp largest_cluster(matches) do
    matches
    |> Enum.map(fn anchor ->
      Enum.filter(matches, &(abs(&1.start_ms - anchor.start_ms) <= @agree_tolerance_ms))
    end)
    |> Enum.max_by(&length/1)
  end

  defp median([]), do: 0

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    mid = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, mid)
    else
      div(Enum.at(sorted, mid - 1) + Enum.at(sorted, mid), 2)
    end
  end
end
