defmodule Mydia.Library.Prune.Eligibility do
  @moduledoc """
  Decides whether a group of files is provably the same content.

  This is the module that keeps prune from destroying media. Most multi-file
  items in a real library are not redundant copies: they are misidentified
  files, one file registered twice, or a feature plus its bonus content.
  Ranking those by quality and trashing the losers deletes real media.

  A group passes only if every check passes. There is no partial prune: a
  group is prunable as a whole or refused as a whole.

  Checks run in the order below and the first failure is the reported reason.
  The order is chosen so the reported reason is the most actionable one. Two
  rows pointing at the same path trivially agree on duration, so the scanner
  bug has to be named before the duration check can call them identical.

    1. `:duplicate_registration` - two rows share library_path_id + relative_path
    2. `:unanalyzed` - a file has no usable duration
    3. `:duration_mismatch` - durations spread wider than 2%
    4. `:name_mismatch` - a filename does not bind to the subject
    5. `:episode_mismatch` - parsed season/episode disagrees with the row
    6. `:nothing_to_prune` - fewer than two files survive

  Checks 4 and 5 live in this module too but are added by the parser task.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Prune.Group

  # Measured against production: 1% admits 164 of 228 candidates, 2% admits
  # 177, 5% admits 199. The step from 2% to 5% is where extended cuts and
  # alternate edits start being admitted, so 2% is the last conservative step.
  @duration_tolerance 0.02

  @type refusal_reason ::
          :duplicate_registration
          | :unanalyzed
          | :duration_mismatch
          | :name_mismatch
          | :episode_mismatch
          | :nothing_to_prune

  @doc """
  Returns `{:ok, group}` when the group is provably the same content, or
  `{:refused, reason, detail}` naming the first failed check.
  """
  @spec check(Group.t()) :: {:ok, Group.t()} | {:refused, refusal_reason(), map()}
  def check(%Group{} = group) do
    with :ok <- check_duplicate_registration(group),
         :ok <- check_analyzed(group),
         :ok <- check_duration_agreement(group),
         :ok <- check_enough_files(group) do
      {:ok, group}
    end
  end

  @doc """
  The duration tolerance, exposed so the UI can explain the refusal.
  """
  @spec duration_tolerance() :: float()
  def duration_tolerance, do: @duration_tolerance

  defp check_duplicate_registration(%Group{files: files}) do
    keys = Enum.map(files, &{&1.library_path_id, &1.relative_path})

    case keys -- Enum.uniq(keys) do
      [] ->
        :ok

      [{_library_path_id, path} | _] ->
        {:refused, :duplicate_registration, %{path: path}}
    end
  end

  defp check_analyzed(%Group{files: files}) do
    unanalyzed = Enum.filter(files, &(duration_of(&1) == nil))

    if unanalyzed == [] do
      :ok
    else
      {:refused, :unanalyzed,
       %{
         unanalyzed_count: length(unanalyzed),
         paths: Enum.map(unanalyzed, & &1.relative_path)
       }}
    end
  end

  defp check_duration_agreement(%Group{files: files}) do
    durations = Enum.map(files, &duration_of/1)
    longest = Enum.max(durations)
    shortest = Enum.min(durations)
    spread = (longest - shortest) / longest

    if spread <= @duration_tolerance do
      :ok
    else
      {:refused, :duration_mismatch,
       %{spread: spread, tolerance: @duration_tolerance, longest: longest, shortest: shortest}}
    end
  end

  defp check_enough_files(%Group{files: files}) do
    if length(files) >= 2, do: :ok, else: {:refused, :nothing_to_prune, %{count: length(files)}}
  end

  # A zero or negative duration is treated as absent rather than as a real
  # value: it is never a usable comparison and it would divide by zero in
  # check_duration_agreement/1.
  defp duration_of(%MediaFile{metadata: %{duration: duration}})
       when is_number(duration) and duration > 0,
       do: duration

  defp duration_of(_file), do: nil
end
