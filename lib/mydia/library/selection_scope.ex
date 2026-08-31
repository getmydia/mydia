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

  A "selected" thing here is an anchor key (`Mydia.Library.ImportCandidateGroup`'s
  identity), not a database id: groups are computed at query time and have no
  id of their own. `to_query/1` delegates the actual query construction to
  `Mydia.ImportCandidates.group_query/2`, so this module owns none of the band
  or search predicates -- there is exactly one definition of each, and this
  and `ImportCandidates.page/2` cannot drift apart.
  """

  import Ecto.Query

  alias Mydia.ImportCandidates
  alias Mydia.Repo

  @max_id_binds 500

  defstruct mode: :none,
            library_path_id: nil,
            status: "pending",
            filter: %{},
            included_ids: MapSet.new(),
            excluded_ids: MapSet.new()

  @type t :: %__MODULE__{
          mode: :none | :page | :filter,
          library_path_id: binary() | nil,
          status: String.t(),
          filter: map(),
          included_ids: MapSet.t(),
          excluded_ids: MapSet.t()
        }

  @doc "An empty selection for one library path and optional status (defaults to pending)."
  @spec new(binary(), String.t()) :: t()
  def new(library_path_id, status \\ "pending"),
    do: %__MODULE__{library_path_id: library_path_id, status: status}

  @doc "Clears the selection, keeping the library path and status."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{library_path_id: id, status: status}), do: new(id, status)

  @doc """
  Selects exactly the given anchor keys, replacing any previous selection.

  Capped at #{@max_id_binds} keys here, at the write boundary, so every reader
  (`count/1`, `selected?/2`, `to_query/1`) sees the same bounded set and none
  of them can disagree about what is actually selected.
  """
  @spec select_page(t(), [String.t()]) :: t()
  def select_page(%__MODULE__{} = scope, anchor_keys) do
    %{
      scope
      | mode: :page,
        included_ids: anchor_keys |> Enum.take(@max_id_binds) |> MapSet.new(),
        excluded_ids: MapSet.new()
    }
  end

  @doc """
  Selects every group matching `filter`, without enumerating them.

  `filter` accepts `:band` and `:q`, the same keys `ImportCandidates.page/2`
  and `group_query/2` take.
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
  never disagree about which anchor keys are actually in play.
  """
  @spec toggle(t(), String.t()) :: t()
  def toggle(%__MODULE__{mode: :filter} = scope, anchor_key) do
    cond do
      MapSet.member?(scope.excluded_ids, anchor_key) ->
        %{scope | excluded_ids: MapSet.delete(scope.excluded_ids, anchor_key)}

      MapSet.size(scope.excluded_ids) >= @max_id_binds ->
        scope

      true ->
        %{scope | excluded_ids: MapSet.put(scope.excluded_ids, anchor_key)}
    end
  end

  def toggle(%__MODULE__{} = scope, anchor_key) do
    cond do
      MapSet.member?(scope.included_ids, anchor_key) ->
        included = MapSet.delete(scope.included_ids, anchor_key)

        %{
          scope
          | mode: if(MapSet.size(included) == 0, do: :none, else: :page),
            included_ids: included
        }

      MapSet.size(scope.included_ids) >= @max_id_binds ->
        scope

      true ->
        %{scope | mode: :page, included_ids: MapSet.put(scope.included_ids, anchor_key)}
    end
  end

  @doc """
  Whether one group is currently selected.

  In `:filter` mode this returns `true` for any anchor key that is not
  explicitly excluded -- including one that does not match the active filter,
  or does not exist at all. That is inherent to a predicate: the scope does
  not hold the matching set, only the filter and the exclusions from it.
  Callers must only ask about anchor keys already known to match the current
  filter (e.g. keys of groups the page actually rendered under that filter);
  asking about anything else gives a meaningless answer.
  """
  @spec selected?(t(), String.t()) :: boolean()
  def selected?(%__MODULE__{mode: :none}, _anchor_key), do: false

  def selected?(%__MODULE__{mode: :page} = scope, anchor_key),
    do: MapSet.member?(scope.included_ids, anchor_key)

  def selected?(%__MODULE__{mode: :filter} = scope, anchor_key),
    do: not MapSet.member?(scope.excluded_ids, anchor_key)

  @doc "How many groups are selected. Counts in SQL for `:filter` mode."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{mode: :none}), do: 0
  def count(%__MODULE__{mode: :page} = scope), do: MapSet.size(scope.included_ids)

  def count(%__MODULE__{} = scope),
    do: scope |> to_query() |> subquery() |> Repo.aggregate(:count)

  @doc """
  The selection as a grouped query over `import_candidates`, delegating to
  `Mydia.ImportCandidates.group_query/2` for the actual aggregation, band, and
  search predicates.

  In `:filter` mode this carries no per-row bind parameters at all, which is
  the whole point of the module: the exclusion set becomes a plain `anchor_key
  NOT IN (...)` filter applied to individual candidate rows before the `GROUP
  BY`, valid because every row in one anchor shares the same `anchor_key`.
  In `:page` mode the anchor key list is already capped at #{@max_id_binds} by
  `select_page/2` and `toggle/2` (the write boundary), so it is used here
  as-is rather than capped again -- capping on read as well would let this
  function and `count/1`/`selected?/2` disagree about which keys are in play.
  """
  @spec to_query(t()) :: Ecto.Query.t()
  def to_query(%__MODULE__{mode: :none} = scope) do
    scope.library_path_id
    |> ImportCandidates.group_query(status: scope.status)
    |> where([c], false)
  end

  def to_query(%__MODULE__{mode: :page} = scope) do
    scope.library_path_id
    |> ImportCandidates.group_query(status: scope.status)
    |> where([c], c.anchor_key in ^MapSet.to_list(scope.included_ids))
  end

  def to_query(%__MODULE__{mode: :filter} = scope) do
    scope.library_path_id
    |> ImportCandidates.group_query(
      status: scope.status,
      band: scope.filter[:band],
      q: scope.filter[:q]
    )
    |> exclude_ids(MapSet.to_list(scope.excluded_ids))
  end

  defp exclude_ids(query, []), do: query

  defp exclude_ids(query, anchor_keys) do
    # Already capped at @max_id_binds by toggle/2 (the write boundary), so
    # used as-is here -- see to_query/1's doc for why capping again on read
    # would be a bug, not a safety net.
    where(query, [c], c.anchor_key not in ^anchor_keys)
  end

  @doc "The per-query id bind cap, exposed for tests and callers that chunk."
  @spec max_id_binds() :: pos_integer()
  def max_id_binds, do: @max_id_binds

  @doc "Serializes a scope into JSON-safe Oban arguments."
  @spec to_args(t()) :: map()
  def to_args(%__MODULE__{} = scope) do
    %{
      "mode" => Atom.to_string(scope.mode),
      "library_path_id" => scope.library_path_id,
      "status" => scope.status,
      "filter" =>
        Map.new(scope.filter, fn {key, value} -> {Atom.to_string(key), encode_filter(value)} end),
      "included_ids" => MapSet.to_list(scope.included_ids),
      "excluded_ids" => MapSet.to_list(scope.excluded_ids)
    }
  end

  @doc "Restores a selection scope from trusted Oban arguments."
  @spec from_args(map()) :: t()
  def from_args(args) do
    %__MODULE__{
      mode: decode_mode(args["mode"]),
      library_path_id: args["library_path_id"],
      status: args["status"] || "pending",
      filter: decode_filter(args["filter"] || %{}),
      included_ids: MapSet.new(args["included_ids"] || []),
      excluded_ids: MapSet.new(args["excluded_ids"] || [])
    }
  end

  defp encode_filter(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_filter(value), do: value

  defp decode_filter(filter) do
    %{}
    |> maybe_put_filter(:q, filter["q"])
    |> maybe_put_filter(:band, decode_band(filter["band"]))
  end

  defp maybe_put_filter(filter, _key, nil), do: filter
  defp maybe_put_filter(filter, key, value), do: Map.put(filter, key, value)

  defp decode_mode("page"), do: :page
  defp decode_mode("filter"), do: :filter
  defp decode_mode(_), do: :none

  defp decode_band("all"), do: :all
  defp decode_band("ready"), do: :ready
  defp decode_band("needs_attention"), do: :needs_attention
  defp decode_band("no_match"), do: :no_match
  defp decode_band(_), do: nil
end
