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

  `Mydia.Library.Prune.Eligibility` applies this to duplicate groups.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Library.PathAnchor
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Media.Episode
  alias Mydia.Settings.LibraryPath

  @type reason :: :wrong_episode | :unbound

  @doc """
  Classifies `files` against `target`. `episode_of` returns the episode row a
  file is attached to, or nil when there is none to compare (movies).

  Files need `:library_path` preloaded.
  """
  @spec classify([MediaFile.t()], TargetContext.t(), (MediaFile.t() -> Episode.t() | nil)) ::
          %{suspects: [{MediaFile.t(), reason()}], nothing_binds?: boolean()}
  def classify(files, %TargetContext{} = target, episode_of) when is_function(episode_of, 1) do
    considered =
      Enum.reject(files, &(is_nil(&1.relative_path) or not is_nil(&1.extra_kind)))

    unbound_ids = for file <- considered, unbound?(file, target), into: MapSet.new(), do: file.id

    bound_anchors =
      for file <- considered,
          not MapSet.member?(unbound_ids, file.id),
          into: MapSet.new(),
          do: anchor_key(file)

    suspects =
      Enum.flat_map(considered, fn file ->
        case reason(file, episode_of.(file), target, unbound_ids, bound_anchors) do
          nil -> []
          reason -> [{file, reason}]
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
end
