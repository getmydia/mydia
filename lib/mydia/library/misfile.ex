defmodule Mydia.Library.Misfile do
  @moduledoc """
  Says which of an item's files look filed against the wrong item.

  A file is a suspect when its name says it is a different episode than the
  row it is attached to (`:wrong_episode`), or when its name does not bind to
  the item and it sits under a different anchor folder (`Mydia.Library.PathAnchor`)
  from every file whose name does bind (`:unbound`). The folder condition
  separates a misattached file from bonus content: a stray from another title
  lives in that title's folder, while a loose featurette sits in the feature's
  folder and fails to bind just the same. A file the extras classifier has
  labelled (`extra_kind` set) is never a suspect, and neither is a legacy row
  with no relative path.

  When no file binds, every unbound file is a suspect and `nothing_binds?` is
  true, which lets a caller tell "nothing here matches" apart from "one stray".

  ## Why the scan needs a stricter title rule

  The parser's binding flag (`:binding_suspect` / `:parsed_title_unbound`)
  fires only below 0.5 title similarity, the same loose score that let #957
  through -- on its own it would miss most of the reported pairs. `scan/0` and
  `send_to_review/2` therefore also pass `strict_titles: true`, which counts a
  file as unbound when its untargeted parsed title falls under 0.75 word
  coverage against every one of the item's names, `Mydia.Downloads.TorrentMatcher`'s
  floor for the same one-directional measure. `Eligibility` keeps the looser
  flag-only rule, so the duplicates page's existing gates do not change.

  `Mydia.Library.Prune.Eligibility` applies this to duplicate groups.

  `scan/0` applies it to every item in the library, and `send_to_review/2`
  detaches suspects after re-verifying them.

  After a provider rename, a file still named by the item's old title is
  flagged as unbound unless that old name is among the item's alternate
  titles (`TargetContext.alt_titles/1`). Such an item usually still has other
  files that do bind, so it lands in ordinary Review rather than the
  `nothing_binds?` bucket -- and sending it there is reversible: the bytes
  stay in place, and `/review` can reattach them.
  """

  import Ecto.Query

  alias Mydia.ImportCandidates
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Misfile.Finding
  alias Mydia.Library.PathAnchor
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Library.Text
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  require Logger

  @type reason :: :wrong_episode | :unbound

  # Mydia.Downloads.TorrentMatcher's floor for the same one-directional measure.
  @title_coverage_floor 0.75

  @scannable_types ["movie", "tv_show"]

  @doc """
  Classifies `files` against `target`. `episode_of` returns the episode row a
  file is attached to, or nil when there is none to compare (movies).

  Files need `:library_path` preloaded. Equivalent to `classify/4` with no
  options.
  """
  @spec classify([MediaFile.t()], TargetContext.t(), (MediaFile.t() -> Episode.t() | nil)) ::
          %{suspects: [{MediaFile.t(), reason()}], nothing_binds?: boolean()}
  def classify(files, %TargetContext{} = target, episode_of) when is_function(episode_of, 1) do
    classify(files, target, episode_of, [])
  end

  @doc """
  Classifies `files` against `target`, like `classify/3`, with options.

  `strict_titles: true` also treats a file as unbound when
  `title_uncovered?/2` says so (see the moduledoc's "Why the scan needs a
  stricter title rule"). `scan/0` and `send_to_review/2` always pass this;
  `Mydia.Library.Prune.Eligibility` keeps calling `classify/3`, so the
  duplicates page's gates do not change.
  """
  @spec classify(
          [MediaFile.t()],
          TargetContext.t(),
          (MediaFile.t() -> Episode.t() | nil),
          keyword()
        ) :: %{suspects: [{MediaFile.t(), reason()}], nothing_binds?: boolean()}
  def classify(files, %TargetContext{} = target, episode_of, opts)
      when is_function(episode_of, 1) and is_list(opts) do
    strict_titles? = Keyword.get(opts, :strict_titles, false)

    considered =
      Enum.reject(files, &(is_nil(&1.relative_path) or not is_nil(&1.extra_kind)))

    unbound_ids =
      for file <- considered,
          unbound?(file, target) or (strict_titles? and title_uncovered?(file, target)),
          into: MapSet.new(),
          do: file.id

    bound_anchors =
      for file <- considered,
          not MapSet.member?(unbound_ids, file.id),
          into: MapSet.new(),
          do: anchor_key(file)

    suspects =
      Enum.flat_map(considered, fn file ->
        case reason(file, episode_of.(file), target, unbound_ids, bound_anchors) do
          nil -> []
          result -> [{file, result}]
        end
      end)

    %{suspects: suspects, nothing_binds?: considered != [] and MapSet.size(bound_anchors) == 0}
  end

  @doc """
  True when the file's name does not bind to the target item. The parser
  already knows how to say "this release name does not belong to this show":
  `:binding_suspect` and `:parsed_title_unbound` are exactly that signal, and
  `Mydia.Downloads.TorrentMatcher` uses the same two flags as a wrong-show
  guard.
  """
  @spec unbound?(MediaFile.t(), TargetContext.t()) :: boolean()
  def unbound?(%MediaFile{relative_path: path}, target) do
    flags =
      path
      |> ReleaseParser.parse_with_path(target: target)
      |> Map.get(:engine_flags)
      |> Kernel.||(%{})

    Map.get(flags, :binding_suspect) == true or not is_nil(Map.get(flags, :parsed_title_unbound))
  end

  @doc """
  True when the file's name gives a season or episode that disagrees with the
  row. A parse with no season or no episode number is not evidence of a
  mismatch.
  """
  @spec wrong_episode?(MediaFile.t(), Episode.t(), TargetContext.t()) :: boolean()
  def wrong_episode?(%MediaFile{relative_path: path}, %Episode{} = episode, target) do
    parsed = ReleaseParser.parse_with_path(path, target: target)

    season_disagrees?(parsed.season, episode.season_number) or
      episode_disagrees?(parsed.episodes, episode.episode_number)
  end

  @doc "The folder that names the media a file sits under, or nil without a library path."
  @spec anchor_key(MediaFile.t()) :: String.t() | nil
  def anchor_key(%MediaFile{library_path: %LibraryPath{path: root}, relative_path: rel})
      when is_binary(root) and is_binary(rel),
      do: PathAnchor.anchor_for(Path.join(root, rel), root).cluster_key

  def anchor_key(%MediaFile{}), do: nil

  @doc """
  Every item in the library with at least one suspect file, sorted by title.

  Parses every active file, so it is for an operator-triggered scan, not a
  render path.
  """
  @spec scan() :: [Finding.t()]
  def scan, do: findings(:all)

  @doc """
  Sends suspect files to Review, after re-verifying each one against a fresh
  classification of its owning item.

  Mirrors `Mydia.Library.Prune.send_to_review/2`, which only accepts files from
  refused duplicate groups. An id that is no longer a suspect is aborted with
  `:not_a_suspect`, and a send that would leave an item with no active file is
  aborted with `:would_leave_no_file`. The bytes stay where they are.
  """
  @spec send_to_review([String.t()], String.t()) :: %{
          returned: [MediaFile.t()],
          failed: [{String.t(), term()}],
          aborted: [{String.t(), :would_leave_no_file | :not_a_suspect}]
        }
  def send_to_review(file_ids, actor_id) when is_list(file_ids) and is_binary(actor_id) do
    requested = MapSet.new(file_ids)

    current =
      case owning_item_ids(file_ids) do
        [] -> []
        item_ids -> findings(item_ids)
      end

    {sendable, whole_item} =
      Enum.reduce(current, {[], []}, fn finding, {to_send, to_abort} ->
        picked =
          for {file, _reason} <- finding.suspects, MapSet.member?(requested, file.id), do: file

        cond do
          picked == [] ->
            {to_send, to_abort}

          length(picked) >= finding.file_count ->
            {to_send, to_abort ++ Enum.map(picked, &{&1.id, :would_leave_no_file})}

          true ->
            {to_send ++ picked, to_abort}
        end
      end)

    known =
      for finding <- current, {file, _reason} <- finding.suspects, into: MapSet.new(), do: file.id

    not_suspect =
      for id <- Enum.uniq(file_ids), not MapSet.member?(known, id), do: {id, :not_a_suspect}

    {returned, failed} =
      Enum.reduce(sendable, {[], []}, fn file, {ok, bad} ->
        case ImportCandidates.return_to_review(file, actor_id) do
          {:ok, deleted} ->
            {ok ++ [deleted], bad}

          {:error, reason} ->
            Logger.error("Misfile could not send a media file to Review",
              media_file_id: file.id,
              reason: inspect(reason)
            )

            {ok, bad ++ [{file.id, reason}]}
        end
      end)

    %{returned: returned, failed: failed, aborted: whole_item ++ not_suspect}
  end

  defp reason(file, episode, target, unbound_ids, bound_anchors) do
    cond do
      match?(%Episode{}, episode) and wrong_episode?(file, episode, target) ->
        :wrong_episode

      MapSet.member?(unbound_ids, file.id) and
          not MapSet.member?(bound_anchors, anchor_key(file)) ->
        :unbound

      true ->
        nil
    end
  end

  defp season_disagrees?(nil, _expected), do: false
  defp season_disagrees?(parsed, expected), do: parsed != expected

  defp episode_disagrees?(nil, _expected), do: false
  defp episode_disagrees?([], _expected), do: false
  defp episode_disagrees?(parsed, expected) when is_list(parsed), do: expected not in parsed
  defp episode_disagrees?(parsed, expected), do: parsed != expected

  defp title_uncovered?(%MediaFile{relative_path: path}, %TargetContext{} = target) do
    case ReleaseParser.parse_with_path(path).title do
      title when is_binary(title) and title != "" ->
        target
        |> item_names()
        |> Enum.all?(&(Text.title_token_coverage(&1, title) < @title_coverage_floor))

      _ ->
        false
    end
  end

  defp item_names(%TargetContext{title: title, alt_titles: alts}) do
    bare = Regex.replace(~r/\s*\(\d{4}\)\s*$/u, title || "", "")

    [title, bare | alts || []]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp findings(item_ids) do
    files_by_item = item_ids |> active_files() |> Enum.group_by(&owning_item_id/1)

    item_ids
    |> scannable_items()
    |> Enum.flat_map(fn item -> finding(item, Map.get(files_by_item, item.id, [])) end)
    |> Enum.sort_by(&String.downcase(&1.media_item.title || ""))
  end

  defp finding(_item, []), do: []

  defp finding(item, files) do
    case classify(files, TargetContext.from_media_item(item), & &1.episode, strict_titles: true) do
      %{suspects: []} ->
        []

      %{suspects: suspects, nothing_binds?: nothing_binds?} ->
        [
          %Finding{
            media_item: item,
            file_count: length(files),
            suspects: suspects,
            nothing_binds?: nothing_binds?
          }
        ]
    end
  end

  # A TV file carries `episode_id` with `media_item_id` NULL, so the owning
  # item comes through the episode (see `Mydia.Library.Prune.Grouping`).
  defp active_files(item_ids) do
    MediaFile
    |> join(:left, [mf], e in assoc(mf, :episode))
    |> where([mf], is_nil(mf.trashed_at))
    |> filter_items(item_ids)
    |> preload([:library_path, :episode])
    |> Repo.all()
  end

  defp filter_items(query, :all), do: query

  defp filter_items(query, item_ids),
    do: where(query, [mf, e], mf.media_item_id in ^item_ids or e.media_item_id in ^item_ids)

  defp scannable_items(item_ids) do
    MediaItem
    |> where([m], m.type in @scannable_types)
    |> then(fn query ->
      if item_ids == :all, do: query, else: where(query, [m], m.id in ^item_ids)
    end)
    |> preload(:episodes)
    |> Repo.all()
  end

  defp owning_item_id(%MediaFile{media_item_id: id}) when is_binary(id), do: id
  defp owning_item_id(%MediaFile{episode: %Episode{media_item_id: id}}), do: id
  defp owning_item_id(%MediaFile{}), do: nil

  defp owning_item_ids(file_ids) do
    MediaFile
    |> join(:left, [mf], e in assoc(mf, :episode))
    |> where([mf], mf.id in ^file_ids)
    |> select([mf, e], coalesce(mf.media_item_id, e.media_item_id))
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
