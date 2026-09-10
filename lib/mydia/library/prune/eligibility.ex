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

  `suspect_files/1` reuses the per-file halves of the name and episode checks
  to say which files in a refused group look misfiled. It is a display and
  default-selection signal for the duplicates page, never a gate.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Library.PathAnchor
  alias Mydia.Library.Prune.Group
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Media.Episode
  alias Mydia.Settings.LibraryPath

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
         :ok <- check_names(group),
         :ok <- check_episode_numbers(group),
         :ok <- check_enough_files(group) do
      {:ok, group}
    end
  end

  @doc """
  The files in a group that look filed against the wrong subject.

  A file is a suspect when its name says it is a different episode than the
  row it is attached to, or when its name does not bind to the item and it sits
  under a different anchor folder (`Mydia.Library.PathAnchor`) from every file
  whose name does bind. The folder condition separates a misattached file from
  bonus content: a stray from another title lives in that title's folder,
  while a loose featurette sits in the feature's folder and fails to bind just
  the same. A file the extras classifier has labelled (`extra_kind` set) is
  never a suspect, and neither is a legacy row with no relative path.

  When no file binds, every unbound file is a suspect, which lets a caller tell
  "nothing here matches" apart from "one stray".
  """
  @spec suspect_files(Group.t()) :: [MediaFile.t()]
  def suspect_files(%Group{media_item: media_item, files: files} = group) do
    target = TargetContext.from_media_item(media_item)

    considered =
      Enum.reject(files, &(is_nil(&1.relative_path) or not is_nil(&1.extra_kind)))

    unbound_ids = for file <- considered, unbound?(file, target), into: MapSet.new(), do: file.id

    bound_anchors =
      for file <- considered,
          not MapSet.member?(unbound_ids, file.id),
          into: MapSet.new(),
          do: anchor_key(file)

    Enum.filter(considered, fn file ->
      wrong_episode_in?(group, file, target) or
        (MapSet.member?(unbound_ids, file.id) and
           not MapSet.member?(bound_anchors, anchor_key(file)))
    end)
  end

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

  # An empty group has no durations to compare. Deferring to
  # check_enough_files/1 keeps the reported reason the documented
  # :nothing_to_prune refusal instead of raising on Enum.max/1.
  defp check_duration_agreement(%Group{files: []}), do: :ok

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

  # Binds every filename to the item the files are attached to. See
  # `unbound?/2` for the signal. `:season_out_of_range` is deliberately not
  # consulted: `check_episode_numbers/1` covers it more precisely against the
  # actual episode row.
  defp check_names(%Group{media_item: media_item, files: files}) do
    target = TargetContext.from_media_item(media_item)

    case Enum.filter(files, &unbound?(&1, target)) do
      [] -> :ok
      unbound -> {:refused, :name_mismatch, %{paths: Enum.map(unbound, & &1.relative_path)}}
    end
  end

  # Movies have no season or episode number to compare, so this check applies
  # to episodes only.
  defp check_episode_numbers(%Group{subject_type: :movie}), do: :ok

  defp check_episode_numbers(
         %Group{subject_type: :episode, subject: %Episode{} = episode} = group
       ) do
    target = TargetContext.from_media_item(group.media_item)

    case Enum.filter(group.files, &wrong_episode?(&1, episode, target)) do
      [] ->
        :ok

      mismatched ->
        {:refused, :episode_mismatch,
         %{
           expected: {episode.season_number, episode.episode_number},
           paths: Enum.map(mismatched, & &1.relative_path)
         }}
    end
  end

  # True when the file's name does not bind to the target item. The parser
  # already knows how to say "this release name does not belong to this show":
  # `:binding_suspect` and `:parsed_title_unbound` are exactly that signal, and
  # `Mydia.Downloads.TorrentMatcher` uses the same two flags as a wrong-show
  # guard.
  defp unbound?(%MediaFile{relative_path: path}, target) do
    flags =
      path
      |> ReleaseParser.parse_with_path(target: target)
      |> Map.get(:engine_flags)
      |> Kernel.||(%{})

    Map.get(flags, :binding_suspect) == true or not is_nil(Map.get(flags, :parsed_title_unbound))
  end

  defp wrong_episode?(%MediaFile{relative_path: path}, %Episode{} = episode, target) do
    parsed = ReleaseParser.parse_with_path(path, target: target)

    season_disagrees?(parsed.season, episode.season_number) or
      episode_disagrees?(parsed.episodes, episode.episode_number)
  end

  defp wrong_episode_in?(
         %Group{subject_type: :episode, subject: %Episode{} = episode},
         file,
         target
       ),
       do: wrong_episode?(file, episode, target)

  defp wrong_episode_in?(_group, _file, _target), do: false

  # The folder that names the media a file sits under. `Prune.Grouping`
  # preloads `:library_path` on every file for exactly this kind of use.
  defp anchor_key(%MediaFile{library_path: %LibraryPath{path: root}, relative_path: rel})
       when is_binary(root) and is_binary(rel),
       do: PathAnchor.anchor_for(Path.join(root, rel), root).cluster_key

  defp anchor_key(%MediaFile{}), do: nil

  # A parse that produced no season or no episode number is not evidence of a
  # mismatch, so it does not refuse here. `check_names/1` has already rejected
  # the filenames that fail to bind at all.
  defp season_disagrees?(nil, _expected), do: false
  defp season_disagrees?(parsed, expected), do: parsed != expected

  defp episode_disagrees?(nil, _expected), do: false
  defp episode_disagrees?([], _expected), do: false
  defp episode_disagrees?(parsed, expected) when is_list(parsed), do: expected not in parsed
  defp episode_disagrees?(parsed, expected), do: parsed != expected

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
