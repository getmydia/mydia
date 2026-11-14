defmodule Mydia.Downloads.WantedFiles do
  @moduledoc """
  Decides which files of a multi-file torrent Mydia will download.

  Season packs often contain episodes the library already owns. Given the
  torrent's file list (relative paths) this module keeps the files worth
  importing and reports which episode each kept video belongs to.

  Junk (samples, extras, anything neither an importable video nor a
  subtitle) is decided by `Mydia.Downloads.FileSelection`, the same rules the
  built-in client's `BuiltIn.FileSelectionPolicy` applies after an add. This
  module adds the episode rules on top.

  See `design/specs/2026-11-14-builtin-torrent-per-file-and-disk-guard-design.md`,
  "Wanted files".
  """

  import Ecto.Query, warn: false

  alias Mydia.Downloads.BuiltIn.FileSelectionPolicy
  alias Mydia.Downloads.FileSelection
  alias Mydia.Downloads.Queue.Duplicates
  alias Mydia.Library.{MediaFile, ReleaseParser}
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Repo

  defstruct only_files: nil,
            selected_bytes: 0,
            file_episodes: %{},
            skipped_owned_episode_ids: [],
            skipped_files: 0

  @type file_map :: %{index: non_neg_integer(), path: String.t(), length: non_neg_integer()}
  @type context :: %{
          optional(:single_episode?) => boolean(),
          media_item: MediaItem.t() | nil,
          season_number: integer() | nil,
          targeted_episode_ids: [binary()]
        }
  @type t :: %__MODULE__{
          only_files: [non_neg_integer()] | nil,
          selected_bytes: non_neg_integer(),
          file_episodes: %{non_neg_integer() => binary()},
          skipped_owned_episode_ids: [binary()],
          skipped_files: non_neg_integer()
        }

  @doc """
  Builds the selection context for a search result.

  Uses `opts[:media_item_id]`, `opts[:episode_id]` and the result's metadata
  (`season_number`, `episode_ids`).
  """
  @spec context_for(map(), keyword()) :: context()
  def context_for(search_result, opts) do
    metadata = Duplicates.normalize_metadata(Map.get(search_result, :metadata))
    episode_id = opts[:episode_id]
    episode = if episode_id, do: Repo.get(Episode, episode_id)
    media_item_id = opts[:media_item_id] || (episode && episode.media_item_id)

    %{
      media_item: if(media_item_id, do: Repo.get(MediaItem, media_item_id)),
      season_number: season_number(metadata, episode),
      targeted_episode_ids: Enum.uniq(List.wrap(episode_id) ++ metadata_episode_ids(metadata)),
      single_episode?: not is_nil(episode_id)
    }
  end

  defp season_number(%{season_number: season}, _episode) when not is_nil(season), do: season
  defp season_number(_metadata, %Episode{season_number: season}), do: season
  defp season_number(_metadata, _episode), do: nil

  defp metadata_episode_ids(%{episode_ids: ids}) when is_list(ids), do: ids
  defp metadata_episode_ids(_metadata), do: []

  @doc "Chooses the files to keep. See the module doc."
  @spec select(context(), [file_map()]) :: t()
  def select(context, files) do
    media_item = context.media_item

    entries =
      files
      |> Enum.map(&classify/1)
      |> Enum.reject(&(&1.kind == :drop))

    if match?(%MediaItem{type: "tv_show"}, media_item) do
      select_episodes(context, files, entries)
    else
      finish(files, entries, %{}, [])
    end
  end

  @doc """
  Serialises a selection for download metadata (string keys).

  A selection also records `BuiltIn.FileSelectionPolicy`'s final `"auto"`
  entry, so the policy treats the torrent as decided and never re-selects
  files this selection skipped. No selection (`nil`: the listing failed or
  the adapter cannot list) records nothing, and the policy deselects junk
  after the add as usual.
  """
  @spec to_metadata(t() | nil) :: map()
  def to_metadata(nil), do: %{}

  def to_metadata(%__MODULE__{} = sel) do
    %{
      "selected_files" => sel.only_files,
      "file_episodes" => Map.new(sel.file_episodes, fn {i, id} -> {to_string(i), id} end),
      "skipped_owned_episode_ids" => sel.skipped_owned_episode_ids,
      FileSelectionPolicy.metadata_key() => FileSelectionPolicy.auto_entry(sel.skipped_files)
    }
  end

  # -- episodes ---------------------------------------------------------

  defp select_episodes(context, files, entries) do
    entries = Enum.map(entries, &parse/1)

    episode_map = lookup_episodes(context, entries)
    owned = owned_episode_ids(Map.values(episode_map) |> Enum.map(& &1.id))
    targeted = MapSet.new(context.targeted_episode_ids)
    single? = Map.get(context, :single_episode?, false)

    keep? = fn ep ->
      single? or MapSet.member?(targeted, ep.id) or not MapSet.member?(owned, ep.id)
    end

    {kept, dropped_ids, file_episodes} =
      Enum.reduce(entries, {[], [], %{}}, fn entry, acc ->
        classify_entry(entry, episode_for(entry, context, episode_map), keep?, acc)
      end)

    finish(files, Enum.reverse(kept), file_episodes, dropped_ids)
  end

  defp classify_entry(entry, nil, _keep?, {kept, dropped, fe}), do: {[entry | kept], dropped, fe}

  defp classify_entry(entry, ep, keep?, {kept, dropped, fe}) do
    if keep?.(ep) do
      {[entry | kept], dropped, record_episode(fe, entry, ep)}
    else
      {kept, [ep.id | dropped], fe}
    end
  end

  # Only videos map to an episode; early import treats every `file_episodes`
  # entry as that episode's media file.
  defp record_episode(fe, %{kind: :video} = entry, ep), do: Map.put(fe, entry.file.index, ep.id)
  defp record_episode(fe, _entry, _ep), do: fe

  defp parse(entry) do
    parsed = ReleaseParser.parse(Path.basename(entry.file.path), [])
    Map.put(entry, :parsed, parsed)
  end

  # Only a file naming exactly one episode of the targeted season is mapped.
  defp episode_for(%{parsed: parsed}, context, episode_map) do
    with [number] <- parsed.episodes,
         season when is_integer(season) <- parsed.season,
         true <- is_nil(context.season_number) or context.season_number == season do
      Map.get(episode_map, {season, number})
    else
      _ -> nil
    end
  end

  defp lookup_episodes(context, entries) do
    keys =
      for %{parsed: %{season: s, episodes: [n]}} <- entries,
          is_integer(s),
          is_nil(context.season_number) or s == context.season_number,
          do: {s, n}

    seasons = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    numbers = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    if keys == [] do
      %{}
    else
      Repo.all(
        from(e in Episode,
          where:
            e.media_item_id == ^context.media_item.id and e.season_number in ^seasons and
              e.episode_number in ^numbers
        )
      )
      |> Map.new(&{{&1.season_number, &1.episode_number}, &1})
    end
  end

  # Mirrors `Queue.Duplicates.all_episodes_have_files?/1`.
  defp owned_episode_ids([]), do: MapSet.new()

  defp owned_episode_ids(ids) do
    from(f in MediaFile,
      where: f.episode_id in ^ids and is_nil(f.trashed_at) and is_nil(f.extra_kind),
      select: f.episode_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # -- common -----------------------------------------------------------

  # Junk is what `FileSelection` calls junk, so this selection and the
  # built-in client's post-add `FileSelectionPolicy` agree: a video the
  # importer would take (not a sample, trailer or extra), or a subtitle.
  defp classify(file) do
    kind =
      cond do
        FileSelection.importable?(file.path) -> :video
        FileSelection.subtitle?(file.path) -> :subtitle
        true -> :drop
      end

    %{file: file, kind: kind}
  end

  defp finish(files, kept, file_episodes, dropped_episode_ids) do
    kept_files = Enum.map(kept, & &1.file)
    kept_indices = kept_files |> Enum.map(& &1.index) |> MapSet.new()
    keeps_video? = Enum.any?(kept, &(&1.kind == :video))

    if length(kept_files) == length(files) or not keeps_video? do
      %__MODULE__{
        only_files: nil,
        selected_bytes: files |> Enum.map(& &1.length) |> Enum.sum(),
        file_episodes: Map.take(file_episodes, MapSet.to_list(kept_indices))
      }
    else
      %__MODULE__{
        only_files: kept_files |> Enum.map(& &1.index) |> Enum.sort(),
        selected_bytes: kept_files |> Enum.map(& &1.length) |> Enum.sum(),
        file_episodes: file_episodes,
        skipped_owned_episode_ids: Enum.uniq(dropped_episode_ids),
        skipped_files: length(files) - length(kept_files)
      }
    end
  end
end
