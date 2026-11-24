defmodule Mydia.Library.BulkRename do
  @moduledoc """
  Library-wide rename: applies the naming template to every file of one library
  path, ignoring the library's `auto_rename` setting.

  Files are grouped by owning media item (a movie's `media_item_id`, or the
  episode's `media_item_id`); files with neither form one "unowned" group whose
  previews never change. Previews are always re-derived here, so `run/2` never
  acts on a stale preview.

  Changed previews that cannot be applied are conflicts and are skipped:
  `:target_exists` when the proposed path is already on disk, and
  `:duplicate_target` when several files in the run propose the same path.
  """

  import Ecto.Query, warn: false

  alias Mydia.Library.{FileMove, FileRenamer, MediaFile}
  alias Mydia.Library.Structs.{BulkRenamePreview, RenamePreview}
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Storage

  @sample_size 20

  @type counts :: %{
          renamed: non_neg_integer(),
          unchanged: non_neg_integer(),
          conflicts: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc "Previews the rename of every file in the library path."
  @spec preview(LibraryPath.t()) :: {:ok, BulkRenamePreview.t()} | {:error, :library_unavailable}
  def preview(%LibraryPath{} = library_path) do
    with :ok <- check_available(library_path) do
      {_groups, previews, conflicts} = plan(library_path)
      changed = Enum.filter(previews, & &1.changed?)
      conflicted = MapSet.new(conflicts, fn {p, _} -> p.file_id end)

      {:ok,
       %BulkRenamePreview{
         total: length(previews),
         changed: length(changed),
         unchanged: length(previews) - length(changed),
         conflicts: conflicts,
         sample:
           changed
           |> Enum.reject(&MapSet.member?(conflicted, &1.file_id))
           |> Enum.take(@sample_size)
       }}
    end
  end

  @doc """
  Renames every changed, non-conflicting file in the library path.

  Options: `:on_progress`, called with `{done, total}` after each media item
  group (default: no-op).
  """
  @spec run(LibraryPath.t(), keyword()) :: {:ok, counts()} | {:error, :library_unavailable}
  def run(%LibraryPath{} = library_path, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress, fn _ -> :ok end)

    with :ok <- check_available(library_path) do
      {groups, _previews, conflicts} = plan(library_path)
      conflicted = MapSet.new(conflicts, fn {p, _} -> p.file_id end)
      total = length(groups)

      counts =
        groups
        |> Enum.with_index(1)
        |> Enum.reduce(%{renamed: 0, unchanged: 0, conflicts: 0, errors: 0}, fn {group, done},
                                                                                acc ->
          acc = Enum.reduce(group, acc, &apply_one(&1, &2, conflicted))
          on_progress.({done, total})
          acc
        end)

      {:ok, counts}
    end
  end

  defp apply_one({file, preview}, acc, conflicted) do
    cond do
      not preview.changed? ->
        Map.update!(acc, :unchanged, &(&1 + 1))

      MapSet.member?(conflicted, preview.file_id) ->
        Map.update!(acc, :conflicts, &(&1 + 1))

      true ->
        case FileRenamer.rename_file(file, preview.proposed_path) do
          {:ok, _} -> Map.update!(acc, :renamed, &(&1 + 1))
          {:error, _} -> Map.update!(acc, :errors, &(&1 + 1))
        end
    end
  end

  # Returns {groups, previews, conflicts}. Each group is a list of
  # {file, preview}.
  defp plan(library_path) do
    groups =
      library_path
      |> list_files()
      |> Enum.group_by(&group_key/1)
      |> Enum.sort_by(fn {key, _} -> to_string(key) end)
      |> Enum.map(fn {_key, files} ->
        Enum.map(files, &{&1, FileRenamer.generate_rename_preview(&1)})
      end)

    previews = groups |> List.flatten() |> Enum.map(&elem(&1, 1))
    {groups, previews, find_conflicts(previews)}
  end

  defp list_files(%LibraryPath{id: id}) do
    from(mf in MediaFile.versions(),
      where: mf.library_path_id == ^id,
      order_by: [asc: mf.relative_path],
      preload: [:library_path, :episode]
    )
    |> Repo.all()
  end

  defp group_key(%MediaFile{media_item_id: id}) when not is_nil(id), do: id
  defp group_key(%MediaFile{episode: %{media_item_id: id}}) when not is_nil(id), do: id
  defp group_key(_), do: :unowned

  defp find_conflicts(previews) do
    changed = Enum.filter(previews, & &1.changed?)

    duplicates =
      changed
      |> Enum.frequencies_by(& &1.proposed_path)
      |> Enum.filter(fn {_, n} -> n > 1 end)
      |> MapSet.new(&elem(&1, 0))

    Enum.flat_map(changed, fn %RenamePreview{} = p ->
      cond do
        MapSet.member?(duplicates, p.proposed_path) ->
          [{p, :duplicate_target}]

        p.proposed_path != p.current_path and FileMove.exists?(p.proposed_path) ->
          [{p, :target_exists}]

        true ->
          []
      end
    end)
  end

  defp check_available(%LibraryPath{path: "s3://" <> _ = path}) do
    with {:ok, source} <- Storage.at(path),
         {:ok, _} <- Storage.stat(source) do
      :ok
    else
      _ -> {:error, :library_unavailable}
    end
  end

  defp check_available(%LibraryPath{path: path}) when is_binary(path) do
    if File.dir?(path), do: :ok, else: {:error, :library_unavailable}
  end

  defp check_available(_), do: {:error, :library_unavailable}
end
