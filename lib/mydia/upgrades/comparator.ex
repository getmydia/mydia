defmodule Mydia.Upgrades.Comparator do
  @moduledoc """
  Decides whether a candidate release is genuinely better than a file on disk.

  Two different questions, both answered with `QualityProfile.score_media_file/2`:

    * the **cutoff** test scores a file on its own, asking "is this good enough
      yet?"
    * the **delta** test scores a normalized candidate against that same file,
      asking "is this specific release actually better?"

  Both sides are normalized through `Mydia.Upgrades.Attrs` first. Dimensions the
  file does not know are neutralized on both sides so that neither a terse
  release title nor a sparsely analyzed file can skew the comparison.

  `ReleaseRanker` is deliberately not used here. It answers "which candidate is
  best", mixing in seeders and indexer priority, which is a different question
  and a different scale.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.Quality
  alias Mydia.Settings.QualityProfile
  alias Mydia.Upgrades.Attrs

  @neutralizable ~w(resolution video_codec audio_codec audio_channels source hdr_tokens file_size_mb)a

  @doc """
  Scores an analyzed file against its profile.

  Returns `{:error, :unscorable}` when the file has never been analyzed or the
  profile carries no quality standards. Both cases would otherwise score 0.0 and
  read as maximally upgradeable, which would make the sweep try to upgrade the
  entire library forever.
  """
  @spec score_file(MediaFile.t(), QualityProfile.t(), :movie | :episode) ::
          {:ok, float()} | {:error, :unscorable}
  # This clause is intentionally permissive on `profile`'s shape (any second
  # argument, not just `%QualityProfile{}`), matching the pre-refactor
  # behavior byte-for-byte: an unanalyzed file is unscorable regardless of
  # what the profile looks like, and `upgrade?/5` below passes `profile`
  # through to this function unguarded. Collapsing this into the general
  # clause (requiring `%QualityProfile{} = profile`) would turn a nil profile
  # + unanalyzed file from a graceful `{:error, :unscorable}` into a
  # `FunctionClauseError` — a real regression caught in review (Task 10
  # finding 4). Keep this clause standalone.
  def score_file(%MediaFile{analyzed_at: nil}, _profile, _media_type),
    do: {:error, :unscorable}

  def score_file(%MediaFile{} = file, %QualityProfile{} = profile, media_type) do
    case score_file_with_breakdown(file, profile, media_type) do
      {:ok, %{score: score}} -> {:ok, score}
      {:error, :unscorable} = error -> error
    end
  end

  @doc """
  Like `score_file/3`, but also returns the per-dimension breakdown
  (`QualityProfile.score_media_file/2`'s `:breakdown` map) alongside the
  score. `score_file/3` is a thin wrapper around this function — this is the
  single source of truth for "is this file even analyzable against this
  profile" (the two guard clauses below).

  Added for `Mydia.Upgrades.finalize_upgrade/1` (Task 10), which records the
  per-dimension breakdown of both files in the activity trail so it can
  answer *why* a replacement decision was made, not just that one was made.
  """
  @spec score_file_with_breakdown(MediaFile.t(), QualityProfile.t(), :movie | :episode) ::
          {:ok, %{score: float(), breakdown: map()}} | {:error, :unscorable}
  def score_file_with_breakdown(%MediaFile{analyzed_at: nil}, _profile, _media_type),
    do: {:error, :unscorable}

  def score_file_with_breakdown(_file, %QualityProfile{quality_standards: nil}, _media_type),
    do: {:error, :unscorable}

  def score_file_with_breakdown(%MediaFile{} = file, %QualityProfile{} = profile, media_type) do
    attrs = Attrs.from_media_file(file, media_type)

    %{score: score, breakdown: breakdown} =
      QualityProfile.score_media_file(profile, compact(attrs))

    {:ok, %{score: score, breakdown: breakdown}}
  end

  @doc """
  Whether a file sits below its profile's upgrade cutoff.
  """
  @spec below_cutoff?(MediaFile.t(), QualityProfile.t(), :movie | :episode) :: boolean()
  def below_cutoff?(_file, %QualityProfile{upgrades_allowed: false}, _media_type), do: false
  def below_cutoff?(_file, %QualityProfile{upgrade_until_score: nil}, _media_type), do: false

  def below_cutoff?(%MediaFile{} = file, %QualityProfile{} = profile, media_type) do
    case score_file(file, profile, media_type) do
      {:ok, score} -> score < profile.upgrade_until_score
      {:error, :unscorable} -> false
    end
  end

  @doc """
  Whether a candidate release beats the file on disk by at least the profile's
  margin.

  Returns `{:ok, %{current:, candidate:, delta:}}` on success, or `{:error,
  :unscorable}` / `{:error, :below_margin}`.
  """
  @spec upgrade?(
          MediaFile.t(),
          Quality.t(),
          non_neg_integer() | nil,
          QualityProfile.t(),
          :movie | :episode
        ) :: {:ok, map()} | {:error, :unscorable | :below_margin}
  def upgrade?(%MediaFile{} = file, %Quality{} = quality, size_bytes, profile, media_type) do
    with {:ok, current} <- score_file(file, profile, media_type) do
      file_attrs = Attrs.from_media_file(file, media_type)
      candidate_attrs = Attrs.from_quality(quality, size_bytes, media_type)
      merged = reconcile(file_attrs, candidate_attrs)

      %{score: candidate} = QualityProfile.score_media_file(profile, compact(merged))
      delta = Float.round(candidate - current, 1)

      if clears_margin?(delta, profile) do
        {:ok, %{current: current, candidate: candidate, delta: delta}}
      else
        {:error, :below_margin}
      end
    end
  end

  @doc """
  Whether a score delta counts as a genuine upgrade under `profile`'s margin.

  The sole authority on that question, shared with
  `Mydia.Upgrades.finalize_upgrade/1` so the gate that picks a candidate and
  the gate that accepts the imported file cannot disagree.

  A margin of 0 - or nil, which an older profile export can still leave behind
  - means "any genuine improvement", **not** "no improvement at all". A plain
  `delta >= margin` accepts a delta of exactly 0.0: an identical-quality
  release is grabbed and the current file trashed, the replacement scores the
  same, and the item is eligible again tomorrow. That is a permanent daily
  churn loop the blacklist cannot break, because the gate passes rather than
  rejecting.
  """
  @spec clears_margin?(float(), QualityProfile.t()) :: boolean()
  def clears_margin?(delta, %QualityProfile{min_upgrade_margin: margin})
      when is_integer(margin) and margin > 0,
      do: delta >= margin

  def clears_margin?(delta, %QualityProfile{}), do: delta > 0

  # Symmetric neutralization. For each comparable dimension:
  #
  #   * file value nil  -> force candidate nil, so both sides hit the same
  #     default and the dimension contributes zero delta
  #   * candidate value nil -> inherit the file's value, so a terse release
  #     title is not penalized for what it failed to mention
  #
  # Without the first rule, a file lacking `source` would score the 50.0
  # missing-key default while a candidate advertising "BluRay" scored 100,
  # handing every candidate a free win.
  defp reconcile(file_attrs, candidate_attrs) do
    Enum.reduce(@neutralizable, candidate_attrs, fn key, acc ->
      case {Map.get(file_attrs, key), Map.get(acc, key)} do
        {nil, _} -> Map.put(acc, key, nil)
        {file_value, nil} -> Map.put(acc, key, file_value)
        {_, _} -> acc
      end
    end)
  end

  # score_media_file/2 branches on key presence, not on nil values, so a nil
  # entry must be dropped rather than passed through.
  defp compact(attrs) do
    attrs
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
