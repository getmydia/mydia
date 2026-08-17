defmodule Mydia.Library.SelectionScope do
  @moduledoc """
  What the user has selected on the review page, as a predicate.

  The obvious model, a set of ids, does not survive its own success: selecting
  everything in a large library and applying produces `WHERE id IN (...)` with
  more bind parameters than either adapter accepts. Postgres caps at 65,535 and
  SQLite at 32,766, so "Select all" was a guaranteed crash with a different
  error on each.

  So selection is a filter plus an exclusion set. `:filter` mode holds no ids at
  all, which means the accept path is one `UPDATE ... WHERE` regardless of how
  many groups it covers.
  """

  import Ecto.Query

  alias Mydia.ImportGroups
  alias Mydia.Library.ImportGroup
  alias Mydia.Repo

  @max_id_binds 500

  defstruct mode: :none,
            library_path_id: nil,
            filter: %{},
            included_ids: MapSet.new(),
            excluded_ids: MapSet.new()

  @type t :: %__MODULE__{
          mode: :none | :page | :filter,
          library_path_id: binary() | nil,
          filter: map(),
          included_ids: MapSet.t(),
          excluded_ids: MapSet.t()
        }

  @doc "An empty selection for one library path."
  @spec new(binary()) :: t()
  def new(library_path_id), do: %__MODULE__{library_path_id: library_path_id}

  @doc "Clears the selection, keeping the library path."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{library_path_id: id}), do: new(id)

  @doc "Selects exactly the given ids, replacing any previous selection."
  @spec select_page(t(), [binary()]) :: t()
  def select_page(%__MODULE__{} = scope, ids) do
    %{scope | mode: :page, included_ids: MapSet.new(ids), excluded_ids: MapSet.new()}
  end

  @doc """
  Selects every group matching `filter`, without enumerating them.

  `filter` accepts `:band` and `:q`, the same keys `ImportGroups.page/2` takes.
  """
  @spec select_all_matching(t(), map()) :: t()
  def select_all_matching(%__MODULE__{} = scope, filter) do
    %{
      scope
      | mode: :filter,
        filter: filter,
        included_ids: MapSet.new(),
        excluded_ids: MapSet.new()
    }
  end

  @doc "Flips one group in or out of the selection."
  @spec toggle(t(), binary()) :: t()
  def toggle(%__MODULE__{mode: :filter} = scope, id) do
    excluded =
      if MapSet.member?(scope.excluded_ids, id),
        do: MapSet.delete(scope.excluded_ids, id),
        else: MapSet.put(scope.excluded_ids, id)

    %{scope | excluded_ids: excluded}
  end

  def toggle(%__MODULE__{} = scope, id) do
    included =
      if MapSet.member?(scope.included_ids, id),
        do: MapSet.delete(scope.included_ids, id),
        else: MapSet.put(scope.included_ids, id)

    %{
      scope
      | mode: if(MapSet.size(included) == 0, do: :none, else: :page),
        included_ids: included
    }
  end

  @doc "Whether one group is currently selected."
  @spec selected?(t(), binary()) :: boolean()
  def selected?(%__MODULE__{mode: :none}, _id), do: false
  def selected?(%__MODULE__{mode: :page} = scope, id), do: MapSet.member?(scope.included_ids, id)

  def selected?(%__MODULE__{mode: :filter} = scope, id),
    do: not MapSet.member?(scope.excluded_ids, id)

  @doc "How many groups are selected. Counts in SQL for `:filter` mode."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{mode: :none}), do: 0
  def count(%__MODULE__{mode: :page} = scope), do: MapSet.size(scope.included_ids)
  def count(%__MODULE__{} = scope), do: Repo.aggregate(to_query(scope), :count)

  @doc """
  The selection as a query over `import_groups`.

  In `:filter` mode this carries no per-row bind parameters at all, which is the
  whole point of the module. In `:page` mode the id list is capped at
  #{@max_id_binds}, comfortably below both adapters' limits.
  """
  @spec to_query(t()) :: Ecto.Query.t()
  def to_query(%__MODULE__{mode: :none}), do: from(g in ImportGroup, where: false)

  def to_query(%__MODULE__{mode: :page} = scope) do
    ids = scope.included_ids |> MapSet.to_list() |> Enum.take(@max_id_binds)

    ImportGroup
    |> where([g], g.library_path_id == ^scope.library_path_id and g.status == "pending")
    |> where([g], g.id in ^ids)
  end

  def to_query(%__MODULE__{mode: :filter} = scope) do
    ImportGroup
    |> where([g], g.library_path_id == ^scope.library_path_id and g.status == "pending")
    |> apply_band(scope.filter[:band])
    |> apply_search(scope.filter[:q])
    |> exclude_ids(MapSet.to_list(scope.excluded_ids))
  end

  defp apply_band(query, nil), do: query
  defp apply_band(query, :all), do: query
  defp apply_band(query, :no_match), do: where(query, [g], is_nil(g.provider_id))

  defp apply_band(query, :ready) do
    threshold = ImportGroups.auto_accept_threshold()
    where(query, [g], not is_nil(g.provider_id) and g.min_confidence >= ^threshold)
  end

  defp apply_band(query, :needs_attention) do
    threshold = ImportGroups.auto_accept_threshold()
    where(query, [g], not is_nil(g.provider_id) and g.min_confidence < ^threshold)
  end

  # `ilike/2` raises on SQLite, so this is a LOWER/LIKE fragment. The explicit
  # ESCAPE clause is not optional: PostgreSQL treats backslash as the implicit
  # LIKE escape, but SQLite has NO escape character unless one is declared, so
  # without it an escaped `%` stays a live wildcard on SQLite and the two
  # adapters return different rows for the same search.
  defp apply_search(query, q) when is_binary(q) and q != "" do
    like = "%" <> escape_like(q) <> "%"

    where(
      query,
      [g],
      fragment("LOWER(?) LIKE LOWER(?) ESCAPE '\\'", g.anchor_path, ^like)
    )
  end

  defp apply_search(query, _), do: query

  # Backslash first, or the escapes added below get escaped again. `_` matters
  # as much as `%` here: it is LIKE's single-character wildcard and shows up in
  # release folder names constantly.
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp exclude_ids(query, []), do: query

  defp exclude_ids(query, ids) do
    # Exclusions are user clicks, so this list is small by construction. Capped
    # anyway rather than trusted.
    where(query, [g], g.id not in ^Enum.take(ids, @max_id_binds))
  end

  @doc "The per-query id bind cap, exposed for tests and callers that chunk."
  @spec max_id_binds() :: pos_integer()
  def max_id_binds, do: @max_id_binds
end
