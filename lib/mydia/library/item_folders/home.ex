defmodule Mydia.Library.ItemFolders.Home do
  @moduledoc """
  The folder an item already lives in within a library, so a download import
  adds to it instead of creating `Title (Year)` beside it
  (getmydia/mydia#1237).

  The folder is derived from the item's active media files with
  `Mydia.Library.ItemFolders.folder_of/1`. A file's path is not proof the
  file is the item's (see "Multi-file items are mostly misidentification" in
  `lib/mydia/media/README.md`), and trusting one misfiled episode would send
  every later episode into another show's folder. So a folder is only used
  when its name carries the item's provider id, or its title matches the
  item's closely and its year does not contradict it.
  """

  import Ecto.Query

  alias Mydia.Library.ItemFolders
  alias Mydia.Library.ItemFolders.Folder
  alias Mydia.Library.MatchScoring
  alias Mydia.Library.MediaFile
  alias Mydia.Library.PathAnchor
  alias Mydia.Library.PathParser
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  # Text.title_similarity/2 scores a bare substring match at 0.8, which would
  # let "Quiet Harbor 2" stand in for "Quiet Harbor".
  @min_title_similarity 0.9

  @doc """
  The trusted folder holding this item's files in `library_path`.

  With `:prefer_file_id` (an upgrade's target file), that file's folder wins
  when it is trusted. Otherwise the trusted folder holding the most files
  wins, ties broken by name. `:none` when no folder qualifies.
  """
  @spec find(MediaItem.t(), LibraryPath.t(), keyword()) :: {:ok, Folder.t()} | :none
  def find(%MediaItem{} = item, %LibraryPath{} = library_path, opts \\ []) do
    prefer = Keyword.get(opts, :prefer_file_id)

    trusted =
      item
      |> files(library_path)
      |> Enum.flat_map(fn file ->
        case ItemFolders.folder_of(file) do
          %Folder{} = folder -> [{file.id, folder}]
          nil -> []
        end
      end)
      |> Enum.filter(fn {_id, folder} -> names_item?(Path.basename(folder.relative), item) end)

    case Enum.find(trusted, fn {id, _folder} -> prefer != nil and id == prefer end) do
      {_id, folder} -> {:ok, folder}
      nil -> most_files(trusted)
    end
  end

  @doc """
  The name of the folder directly under `show_dir` that already holds this
  show's files for `season`, or nil. Keeps a library that uses `Season 1`
  from growing a parallel `Season 01`.
  """
  @spec season_folder_name(MediaItem.t(), LibraryPath.t(), String.t(), non_neg_integer()) ::
          String.t() | nil
  def season_folder_name(%MediaItem{} = item, %LibraryPath{} = library_path, show_dir, season) do
    prefix = String.trim_trailing(show_dir, "/") <> "/"

    item
    |> files(library_path)
    |> Enum.flat_map(fn file ->
      with path when is_binary(path) <- MediaFile.storage_path(file),
           true <- String.starts_with?(path, prefix),
           [segment, _ | _] <- path |> String.replace_prefix(prefix, "") |> Path.split(),
           {:season, ^season} <- PathAnchor.classify_segment(segment) do
        [segment]
      else
        _ -> []
      end
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {name, count} -> {-count, name} end)
    |> case do
      [{name, _} | _] -> name
      [] -> nil
    end
  end

  # Movies own their files directly; a TV file's media_item_id is NULL and
  # its show hangs off the episode (lib/mydia/media/README.md).
  defp files(%MediaItem{id: item_id}, %LibraryPath{id: lp_id} = library_path) do
    from(f in MediaFile,
      left_join: e in assoc(f, :episode),
      where: f.library_path_id == ^lp_id,
      where: is_nil(f.trashed_at) and is_nil(f.extra_kind),
      where: f.media_item_id == ^item_id or e.media_item_id == ^item_id,
      order_by: [asc: f.relative_path]
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | library_path: library_path})
  end

  defp names_item?(name, %MediaItem{} = item) do
    tags = PathParser.external_id_tags(name)
    own = own_ids(item)

    cond do
      Enum.any?(tags, fn {provider, id} ->
        Map.has_key?(own, provider) and own[provider] != normalize_id(id)
      end) ->
        false

      Enum.any?(tags, fn {provider, id} -> own[provider] == normalize_id(id) end) ->
        true

      true ->
        title_matches?(PathParser.strip_external_ids(name), item)
    end
  end

  defp title_matches?(name, %MediaItem{title: title, year: year}) when is_binary(title) do
    {folder_title, folder_year} = MatchScoring.split_title_year(name)
    {item_title, _} = MatchScoring.split_title_year(title)

    MatchScoring.title_similarity(folder_title, item_title) >= @min_title_similarity and
      not MatchScoring.year_contradiction?(year, folder_year)
  end

  defp title_matches?(_name, _item), do: false

  defp own_ids(%MediaItem{} = item) do
    [tmdb: item.tmdb_id, tvdb: item.tvdb_id, imdb: item.imdb_id]
    |> Enum.reject(fn {_provider, id} -> is_nil(id) end)
    |> Map.new(fn {provider, id} -> {provider, normalize_id(id)} end)
  end

  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(id) when is_binary(id), do: String.downcase(id)

  defp most_files([]), do: :none

  defp most_files(trusted) do
    {_id, folder} =
      trusted
      |> Enum.group_by(fn {_id, folder} -> folder.relative end)
      |> Enum.min_by(fn {relative, group} -> {-length(group), relative} end)
      |> elem(1)
      |> hd()

    {:ok, folder}
  end
end
