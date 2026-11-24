defmodule Mydia.Library.BulkRename do
  @moduledoc """
  Library-wide rename: applies the naming template to every file of one library
  path, ignoring the library's `auto_rename` setting.

  Files are grouped by owning media item (a movie's `media_item_id`, or the
  episode's `media_item_id`); files with neither form one "unowned" group whose
  previews never change. Previews are always re-derived here, so `run/2` never
  acts on a stale preview, and each group's rows are re-read just before it is
  renamed: a file whose row vanished or whose preview changed since planning is
  skipped and counted unchanged.

  Changed previews that cannot be applied are conflicts and are skipped:
  `:target_exists` when the proposed path is already on disk, and
  `:duplicate_target` when several files in the run propose the same path.
  """

  import Ecto.Query, warn: false

  require Logger

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
          acc = group |> refresh(library_path) |> Enum.reduce(acc, &apply_one(&1, &2, conflicted))
          on_progress.({done, total})
          acc
        end)

      {:ok, counts}
    end
  end

  # The plan is minutes old by the time a late group runs, so each group's
  # rows are re-read just before renaming it. A file whose row vanished (gone,
  # trashed, moved to another library) or whose preview no longer matches the
  # plan is skipped: its new name was never checked against the run's
  # conflicts. Conflicts themselves still come from the up-front plan.
  defp refresh(group, %LibraryPath{id: library_path_id}) do
    ids = for {_file, preview} <- group, preview.changed?, do: preview.file_id

    fresh =
      from(mf in MediaFile.versions(),
        where: mf.id in ^ids and mf.library_path_id == ^library_path_id,
        preload: [:library_path, :episode]
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(group, fn
      {_file, %RenamePreview{changed?: false}} = entry -> entry
      {_file, preview} -> {Map.get(fresh, preview.file_id), preview}
    end)
  end

  defp apply_one({file, preview}, acc, conflicted) do
    cond do
      not preview.changed? ->
        Map.update!(acc, :unchanged, &(&1 + 1))

      MapSet.member?(conflicted, preview.file_id) ->
        Map.update!(acc, :conflicts, &(&1 + 1))

      stale?(file, preview) ->
        Logger.info("Library rename skipped a file that changed since planning",
          file_id: preview.file_id
        )

        Map.update!(acc, :unchanged, &(&1 + 1))

      true ->
        case FileRenamer.rename_file(file, preview.proposed_path) do
          {:ok, _} ->
            Map.update!(acc, :renamed, &(&1 + 1))

          {:error, reason} ->
            Logger.warning("Library rename failed for file",
              file_id: preview.file_id,
              reason: inspect(reason)
            )

            Map.update!(acc, :errors, &(&1 + 1))
        end
    end
  end

  defp stale?(nil, _preview), do: true

  defp stale?(file, preview) do
    fresh = FileRenamer.generate_rename_preview(file)
    fresh.current_path != preview.current_path or fresh.proposed_path != preview.proposed_path
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

  defp check_available(%LibraryPath{path: path} = library_path) when is_binary(path) do
    with {:ok, location} <- Storage.location(library_path),
         :ok <- Storage.validate(location) do
      :ok
    else
      _ -> {:error, :library_unavailable}
    end
  end

  defp check_available(_), do: {:error, :library_unavailable}
end
