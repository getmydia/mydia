defmodule Mydia.Library.TargetResolver do
  @moduledoc """
  Decides which library a media item's content belongs in.

  This is the single authority for that question. Import, rematch and the
  detail page all route through `resolve/2` so they cannot disagree.

  Resolution order, first match wins:

    1. `:download_override`  - the download row's own `library_path_id`
    2. `:explicit`           - the media item's `library_path_id`
    3. `:existing_files`     - where this item's non-trashed files already live
    4. `:type_default`       - the operator-set default for the item's kind
    5. `:first_compatible`   - the historical rule: first compatible library by
                               `Settings.list_library_paths/1` ordering

  Step 5 is deliberately the pre-existing behaviour, so an install that never
  configures a default resolves exactly as it did before this module existed.

  ## Candidate validation

  Each step produces a candidate that must pass a check before being accepted;
  a failing candidate falls through rather than aborting, because a library can
  be deleted, disabled or retyped long after an item started pointing at it.

  The check differs by step on purpose. An **explicit** choice requires only
  that the library exists, is not disabled, and is type-compatible. It does not
  require `monitored`: unmonitoring means "stop scanning", usually because a
  drive is offline, and silently rerouting an explicit choice to a different
  disk is how one movie ends up in two places. Inferred steps additionally
  require `monitored`, matching the historical behaviour.
  """

  import Ecto.Query

  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath

  @type reason ::
          :download_override | :explicit | :existing_files | :type_default | :first_compatible

  @movie_types [:movies, :mixed]
  @series_types [:series, :mixed]

  @doc """
  Resolves the target library for `media_item`.

  ## Options

    * `:download` - the `%Mydia.Downloads.Download{}` being imported, if any.
      Its `library_path` association supplies step 1.
    * `:library_paths` - candidate list, defaulting to
      `Settings.list_library_paths/0`. Injectable so tests need no global state.
  """
  @spec resolve(MediaItem.t(), keyword()) ::
          {:ok, LibraryPath.t(), reason()} | {:error, :no_compatible_library}
  def resolve(%MediaItem{} = media_item, opts \\ []) do
    library_paths = Keyword.get_lazy(opts, :library_paths, &Settings.list_library_paths/0)
    kind = kind_for(media_item)
    allowed = allowed_types(kind)

    steps = [
      {:download_override, fn -> download_target(opts[:download]) end, :no_validation},
      {:explicit, fn -> explicit_target(media_item, library_paths) end, :explicit_rules},
      {:existing_files, fn -> files_target(media_item, library_paths) end, :inferred_rules},
      {:type_default, fn -> default_target(kind) end, :inferred_rules},
      {:first_compatible, fn -> first_compatible(library_paths, allowed) end, :inferred_rules}
    ]

    Enum.find_value(steps, {:error, :no_compatible_library}, fn {reason, produce, rules} ->
      case produce.() do
        nil -> nil
        candidate -> if acceptable?(candidate, allowed, rules), do: {:ok, candidate, reason}
      end
    end)
  end

  @doc """
  The library types that can hold content of `kind`.
  """
  @spec allowed_types(:movies | :series) :: [atom()]
  def allowed_types(:movies), do: @movie_types
  def allowed_types(:series), do: @series_types

  @doc """
  Maps a media item to the kind of library it belongs in.
  """
  @spec kind_for(MediaItem.t()) :: :movies | :series
  def kind_for(%MediaItem{type: "movie"}), do: :movies
  def kind_for(%MediaItem{}), do: :series

  ## Candidate producers

  defp download_target(nil), do: nil
  defp download_target(%{library_path: %LibraryPath{} = library_path}), do: library_path
  defp download_target(_), do: nil

  defp explicit_target(%MediaItem{library_path_id: nil}, _paths), do: nil

  defp explicit_target(%MediaItem{library_path_id: id}, paths) do
    Enum.find(paths, &(to_string(&1.id) == to_string(id))) || Repo.get(LibraryPath, id)
  end

  defp files_target(%MediaItem{id: id}, paths) do
    MediaFile
    |> where([f], f.media_item_id == ^id)
    |> where([f], is_nil(f.trashed_at))
    |> where([f], not is_nil(f.library_path_id))
    |> group_by([f], f.library_path_id)
    |> order_by([f], desc: count(f.id), desc: max(f.inserted_at))
    |> limit(1)
    |> select([f], f.library_path_id)
    |> Repo.one()
    |> case do
      nil -> nil
      library_path_id -> Enum.find(paths, &(to_string(&1.id) == to_string(library_path_id)))
    end
  end

  defp default_target(kind), do: Settings.default_library_for(kind)

  defp first_compatible(paths, allowed) do
    Enum.find(paths, &(&1.type in allowed and &1.monitored))
  end

  ## Candidate validation

  # A download-level override is honoured as-is. It is the pre-existing
  # specialized-library escape hatch (music, books, adult) whose type would
  # never satisfy a movie's or show's allow-list, and the design leaves that
  # step unchanged.
  defp acceptable?(%LibraryPath{}, _allowed, :no_validation), do: true

  defp acceptable?(%LibraryPath{} = candidate, allowed, rules) do
    candidate.type in allowed and not disabled?(candidate) and
      (rules == :explicit_rules or candidate.monitored)
  end

  defp acceptable?(_, _, _), do: false

  defp disabled?(%LibraryPath{disabled: true}), do: true
  defp disabled?(_), do: false
end
