defmodule Mydia.Library.ExtraClassifier do
  @moduledoc """
  Decides which of a movie's files are versions of the movie and which are
  bonus content.

  This is the third of `Mydia.Library.SampleDetector`'s documented layers, the
  one that needs a duration. It runs after `Mydia.Jobs.FileAnalysis` rather
  than at scan time, because at the scan gate the row does not exist yet.

  ## The rule

  A file is an extra when it runs at under half its movie's published runtime.
  The comparison is one-sided: a file *longer* than the runtime is never
  demoted, because extended and director's cuts run long while bonus content
  runs short.

  Calibrated against galactica on 2026-08-28 over 354 movie files. The
  distribution is bimodal with an empty band between ratio 0.30 and 0.50: 144
  files below 0.30, one at 0.499, then nothing until 0.614. The nearest
  genuine feature above the line is LEGO Frozen: Operation Puffins at 0.896,
  a 16.1 minute film with an 18 minute published runtime, so the threshold has
  roughly 0.4 of headroom to the closest real film.

  ## What it deliberately misses

  Long-form extras. On galactica three files stay versions: Fantastic Mr. Fox's
  `Roald Dahl Reads Fantastic Mr. Fox` (0.614), `Fantastic Mr. Dahl` (0.706)
  and `Animatic version of the film` (0.864). Catching the animatic would
  require a threshold above LEGO Frozen's 0.896, which would demote real
  films. The operator demote control covers these instead.

  This module also does not diagnose misidentification. A folder holding four
  full Shrek features under a 28 minute special leaves all four as versions,
  correctly, since none of them is short.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Library.SampleDetector

  # A file is an extra below this fraction of the reference duration. See the
  # calibration figures in the moduledoc before changing it.
  @ratio 0.5

  # The invariant below rescues a file only when it is at least this fraction of
  # the reference. Calibrated on the same production sample as @ratio: the
  # 0.30-0.50 band holds exactly one file (a misidentified feature at 0.499)
  # and 0.20-0.30 holds five genuine extras, so 0.30 sits in a measured empty
  # band. Without this floor a folder holding only a three minute clip promotes
  # that clip to a version, and the movie falsely reports as owned.
  @rescue_floor 0.30

  @type decision :: :version | :extra

  @doc """
  Classifies a movie's files.

  `runtime_minutes` is `media_item.metadata.runtime`, in minutes. Durations on
  the files are in seconds. Returns a map of media file id to decision. Files
  with no duration are omitted rather than guessed at, and callers must leave
  those rows untouched.
  """
  @spec classify(pos_integer() | nil, [MediaFile.t()]) :: %{binary() => decision()}
  def classify(runtime_minutes, files) when is_list(files) do
    case Enum.filter(files, &duration/1) do
      [] ->
        %{}

      eligible ->
        {reference, source} = reference_duration(runtime_minutes, eligible)

        eligible
        |> Map.new(fn file -> {file.id, decide(file, reference)} end)
        |> apply_invariant(eligible, reference, source)
    end
  end

  # The published runtime is the reference when we have one. Failing that, the
  # longest sibling stands in for the feature, which only makes sense with at
  # least two files to compare. A lone file with neither falls through to the
  # absolute floor.
  defp reference_duration(runtime_minutes, _eligible)
       when is_number(runtime_minutes) and runtime_minutes > 0 do
    {runtime_minutes * 60, :runtime}
  end

  defp reference_duration(_runtime_minutes, [_single]), do: {nil, :floor}

  defp reference_duration(_runtime_minutes, eligible) do
    {eligible |> Enum.map(&duration/1) |> Enum.max(), :sibling}
  end

  defp decide(file, nil) do
    if SampleDetector.sample_by_duration?(duration(file), expected_type: :movie),
      do: :extra,
      else: :version
  end

  defp decide(file, reference) do
    if duration(file) < @ratio * reference, do: :extra, else: :version
  end

  # An item always keeps at least one version, so a wrong published runtime can
  # never empty a movie — but only when the longest file is plausibly the
  # feature. Rescuing a file that is obviously a clip would defeat the
  # ownership guarantee this exists to protect: a folder holding nothing but a
  # three minute bonus clip must still report the movie as not owned. Mirrors
  # the successor promotion in Mydia.Library.Prune.Ranker.decide/2.
  #
  # Only applied when the reference was the published runtime, the one input
  # that can be externally wrong. A sibling-derived reference always leaves its
  # own longest file a version anyway, and a floor decision on a lone file is
  # confident enough to stand.
  defp apply_invariant(decisions, _eligible, _reference, source) when source != :runtime,
    do: decisions

  defp apply_invariant(decisions, eligible, reference, :runtime) do
    if Enum.any?(decisions, fn {_id, decision} -> decision == :version end) do
      decisions
    else
      longest = Enum.max_by(eligible, &duration/1)

      if duration(longest) >= @rescue_floor * reference do
        Map.put(decisions, longest.id, :version)
      else
        decisions
      end
    end
  end

  defp duration(%MediaFile{metadata: %{duration: duration}})
       when is_number(duration) and duration > 0,
       do: duration

  defp duration(_file), do: nil
end
