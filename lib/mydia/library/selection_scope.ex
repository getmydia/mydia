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

  @doc """
  Selects exactly the given ids, replacing any previous selection.

  Capped at #{@max_id_binds} ids here, at the write boundary, so every reader
  (`count/1`, `selected?/2`, `to_query/1`) sees the same bounded set and none
  of them can disagree about what is actually selected.
  """
  @spec select_page(t(), [binary()]) :: t()
  def select_page(%__MODULE__{} = scope, ids) do
    %{
      scope
      | mode: :page,
        included_ids: ids |> Enum.take(@max_id_binds) |> MapSet.new(),
        excluded_ids: MapSet.new()
    }
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

  @doc """
  Flips one group in or out of the selection.

  Removing is always allowed. Adding is refused once the growing set (the
  exclusion set in `:filter` mode, the inclusion set otherwise) reaches
  #{@max_id_binds}: the scope is returned unchanged rather than growing past
  the cap this module exists to enforce. This is the same write-boundary cap
  `select_page/2` applies, so `count/1`, `selected?/2` and `to_query/1` can
  never disagree about which ids are actually in play.
  """
  @spec toggle(t(), binary()) :: t()
  def toggle(%__MODULE__{mode: :filter} = scope, id) do
    cond do
      MapSet.member?(scope.excluded_ids, id) ->
        %{scope | excluded_ids: MapSet.delete(scope.excluded_ids, id)}

      MapSet.size(scope.excluded_ids) >= @max_id_binds ->
        scope

      true ->
        %{scope | excluded_ids: MapSet.put(scope.excluded_ids, id)}
    end
  end

  def toggle(%__MODULE__{} = scope, id) do
    cond do
      MapSet.member?(scope.included_ids, id) ->
        included = MapSet.delete(scope.included_ids, id)

        %{
          scope
          | mode: if(MapSet.size(included) == 0, do: :none, else: :page),
            included_ids: included
        }

      MapSet.size(scope.included_ids) >= @max_id_binds ->
        scope

      true ->
        %{scope | mode: :page, included_ids: MapSet.put(scope.included_ids, id)}
    end
  end

  @doc """
  Whether one group is currently selected.

  In `:filter` mode this returns `true` for any id that is not explicitly
  excluded — including an id that does not match the active filter, or does
  not exist at all. That is inherent to a predicate: the scope does not hold
  the matching set, only the filter and the exclusions from it. Callers must
  only ask about ids already known to match the current filter (e.g. ids of
  rows the page actually rendered under that filter); asking about anything
  else gives a meaningless answer.
  """
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
  whole point of the module. In `:page` mode the id list is already capped at
  #{@max_id_binds} by `select_page/2` and `toggle/2` (the write boundary), so
  it is used here as-is rather than capped again — capping on read as well
  would let this function and `count/1`/`selected?/2` disagree about which ids
  are in play.
  """
  @spec to_query(t()) :: Ecto.Query.t()
  def to_query(%__MODULE__{mode: :none}), do: from(g in ImportGroup, where: false)

  def to_query(%__MODULE__{mode: :page} = scope) do
    ImportGroup
    |> where([g], g.library_path_id == ^scope.library_path_id and g.status == "pending")
    |> where([g], g.id in ^MapSet.to_list(scope.included_ids))
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
    # Already capped at @max_id_binds by toggle/2 (the write boundary), so
    # used as-is here — see to_query/1's doc for why capping again on read
    # would be a bug, not a safety net.
    where(query, [g], g.id not in ^ids)
  end

  @doc "The per-query id bind cap, exposed for tests and callers that chunk."
  @spec max_id_binds() :: pos_integer()
  def max_id_binds, do: @max_id_binds
end
