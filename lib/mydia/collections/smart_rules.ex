defmodule Mydia.Collections.SmartRules do
  @moduledoc """
  Builds dynamic Ecto queries from JSON smart collection rule definitions.

  ## Rules Format

  Smart rules are defined as a JSON object with the following structure:

      %{
        "match_type" => "all",  # "all" (AND) or "any" (OR)
        "conditions" => [
          %{"field" => "category", "operator" => "in", "value" => ["movie", "anime_movie"]},
          %{"field" => "year", "operator" => "gte", "value" => 2020},
          %{"field" => "metadata.vote_average", "operator" => "gte", "value" => 7.0}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"},  # optional
        "limit" => 100  # optional
      }

  ## Supported Fields

  - `category` - Media category (movie, anime_movie, tv_show, etc.)
  - `type` - Media type (movie or tv_show)
  - `year` - Release year
  - `title` - Title (for text search)
  - `monitored` - Monitored status
  - `metadata.vote_average` - Rating from TMDB
  - `metadata.genres` - Genres array
  - `metadata.original_language` - Original language code
  - `metadata.status` - Status (Ended, Returning Series, etc.)
  - `inserted_at` - Date added to library

  ## Supported Operators

  - `eq` - Equal
  - `gt` - Greater than
  - `gte` - Greater than or equal
  - `lt` - Less than
  - `lte` - Less than or equal
  - `in` - Value is in list
  - `not_in` - Value is not in list
  - `contains` - String/array contains value
  - `contains_any` - Array contains any of the values
  - `between` - Value is between two numbers [min, max]
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  alias Mydia.Accounts.Scope
  alias Mydia.Media.MediaItem
  alias Mydia.Media.Restrictions
  alias Mydia.Repo
  alias Mydia.DB

  @valid_fields ~w(
    category type year title monitored
    metadata.vote_average metadata.genres metadata.original_language metadata.status
    inserted_at
  )

  @valid_operators ~w(eq gt gte lt lte in not_in contains contains_any between)

  @valid_sort_fields ~w(title year rating added_date position)
  @valid_sort_directions ~w(asc desc)

  # Fields that require string values
  @string_fields ~w(category type title metadata.original_language metadata.status)

  # Fields that require numeric values
  @numeric_fields ~w(year metadata.vote_average)

  # Fields that require boolean values
  @boolean_fields ~w(monitored)

  # Valid type values
  @valid_type_values ~w(movie tv_show)

  @doc """
  Validates a smart rules definition.

  Returns `{:ok, rules}` if valid, or `{:error, errors}` with a list of validation errors.

  ## Examples

      iex> validate(%{"match_type" => "all", "conditions" => []})
      {:ok, %{"match_type" => "all", "conditions" => []}}

      iex> validate(%{"match_type" => "invalid"})
      {:error, ["match_type must be 'all' or 'any'"]}
  """
  def validate(rules) when is_binary(rules) do
    case Jason.decode(rules) do
      {:ok, decoded} -> validate(decoded)
      {:error, _} -> {:error, ["Invalid JSON"]}
    end
  end

  def validate(rules) when is_map(rules) do
    errors = []

    # Validate match_type
    errors =
      case Map.get(rules, "match_type") do
        nil -> errors
        type when type in ["all", "any"] -> errors
        _ -> ["match_type must be 'all' or 'any'" | errors]
      end

    # Validate conditions
    conditions = Map.get(rules, "conditions", [])

    errors =
      if is_list(conditions) do
        condition_errors =
          conditions
          |> Enum.with_index()
          |> Enum.flat_map(fn {condition, idx} -> validate_condition(condition, idx) end)

        errors ++ condition_errors
      else
        ["conditions must be a list" | errors]
      end

    # Validate sort (optional)
    errors =
      case Map.get(rules, "sort") do
        nil ->
          errors

        sort when is_map(sort) ->
          sort_errors = validate_sort(sort)
          errors ++ sort_errors

        _ ->
          ["sort must be an object" | errors]
      end

    # Validate limit (optional)
    errors =
      case Map.get(rules, "limit") do
        nil -> errors
        limit when is_integer(limit) and limit > 0 -> errors
        _ -> ["limit must be a positive integer" | errors]
      end

    if errors == [] do
      {:ok, rules}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  def validate(_), do: {:error, ["Rules must be a map or JSON string"]}

  @doc """
  Executes a smart rules query and returns matching media items.

  ## Options
    - `:preload` - List of associations to preload
    - `:limit` - Override the limit in rules
    - `:offset` - Number of items to skip

  `scope`, when given, applies `Mydia.Media.Restrictions.apply/2` right after
  the base `MediaItem` query is built, so a restricted caller never sees rows
  outside their allowed categories or age limit, however permissive the rules
  themselves are. `nil` (the default) applies no restriction, which keeps this
  a backwards-compatible arity for callers with no scope to give, such as
  `Collections.item_count/1`.

  Returns `{:ok, items}` on success or `{:error, reason}` on failure.
  For backwards compatibility, you can also use `execute_query!/3` which
  returns items directly or an empty list on error.
  """
  def execute_query(rules, opts \\ [], scope \\ nil)

  def execute_query(rules, opts, scope) when is_map(rules) do
    # First validate the rules
    case validate(rules) do
      {:ok, _} ->
        try do
          items =
            rules
            |> build_query()
            |> maybe_apply_scope(scope)
            |> apply_sort(rules)
            |> apply_limit(rules, opts)
            |> apply_offset(opts)
            |> maybe_preload(opts[:preload])
            |> Repo.all()

          {:ok, items}
        rescue
          e in Ecto.Query.CastError ->
            {:error, "Query failed: #{Exception.message(e)}"}

          e in Ecto.QueryError ->
            {:error, "Query failed: #{Exception.message(e)}"}
        end

      {:error, errors} ->
        {:error, "Invalid rules: #{Enum.join(errors, ", ")}"}
    end
  end

  def execute_query(rules, opts, scope) when is_binary(rules) do
    case Jason.decode(rules) do
      {:ok, decoded} -> execute_query(decoded, opts, scope)
      {:error, _} -> {:error, "Invalid JSON"}
    end
  end

  @doc """
  Executes a smart rules query and returns items directly.
  Returns an empty list on any error. See `execute_query/3` for `scope`.
  """
  def execute_query!(rules, opts \\ [], scope \\ nil) do
    case execute_query(rules, opts, scope) do
      {:ok, items} -> items
      {:error, _} -> []
    end
  end

  @doc """
  Returns the count of items matching the smart rules.
  Returns 0 on any error. See `execute_query/3` for `scope`.
  """
  def execute_count(rules, scope \\ nil)

  def execute_count(rules, scope) when is_map(rules) do
    case validate(rules) do
      {:ok, _} ->
        try do
          rules
          |> build_query()
          |> maybe_apply_scope(scope)
          |> apply_limit(rules, [])
          |> Repo.aggregate(:count)
        rescue
          Ecto.Query.CastError -> 0
          Ecto.QueryError -> 0
        end

      {:error, _} ->
        0
    end
  end

  def execute_count(rules, scope) when is_binary(rules) do
    case Jason.decode(rules) do
      {:ok, decoded} -> execute_count(decoded, scope)
      {:error, _} -> 0
    end
  end

  @doc """
  Returns a preview of items matching the rules (limited to 10 items).
  Useful for showing users what a smart collection will contain.
  See `execute_query/3` for `scope`.
  """
  def preview(rules, limit \\ 10, scope \\ nil) do
    execute_query!(rules, [limit: limit], scope)
  end

  @doc """
  Returns the list of valid fields for smart rules.
  """
  def valid_fields, do: @valid_fields

  @doc """
  Returns the list of valid operators for smart rules.
  """
  def valid_operators, do: @valid_operators

  ## Private Functions

  defp validate_condition(condition, idx) when is_map(condition) do
    errors = []
    prefix = "conditions[#{idx}]"

    field = Map.get(condition, "field")
    operator = Map.get(condition, "operator")
    value = Map.get(condition, "value")

    errors =
      cond do
        is_nil(field) -> ["#{prefix}: field is required" | errors]
        field not in @valid_fields -> ["#{prefix}: unknown field '#{field}'" | errors]
        true -> errors
      end

    errors =
      cond do
        is_nil(operator) -> ["#{prefix}: operator is required" | errors]
        operator not in @valid_operators -> ["#{prefix}: unknown operator '#{operator}'" | errors]
        true -> errors
      end

    # Validate value based on operator
    errors =
      cond do
        is_nil(value) ->
          ["#{prefix}: value is required" | errors]

        operator in ["in", "not_in", "contains_any"] and not is_list(value) ->
          ["#{prefix}: value must be a list for operator '#{operator}'" | errors]

        operator == "between" and
            not (is_list(value) and length(value) == 2) ->
          ["#{prefix}: value must be a [min, max] list for 'between'" | errors]

        true ->
          errors
      end

    # Validate value type matches field type
    errors = validate_field_value_type(field, value, operator, prefix, errors)

    errors
  end

  defp validate_condition(_, idx) do
    ["conditions[#{idx}]: must be an object"]
  end

  # Validates that the value type is compatible with the field
  defp validate_field_value_type(field, value, _operator, _prefix, errors)
       when is_nil(field) or is_nil(value) do
    errors
  end

  defp validate_field_value_type("type", value, operator, prefix, errors)
       when operator in ["in", "not_in"] do
    invalid_values =
      value
      |> List.wrap()
      |> Enum.reject(&(&1 in @valid_type_values))

    if invalid_values == [] do
      errors
    else
      [
        "#{prefix}: invalid type value(s): #{Enum.join(invalid_values, ", ")}. Valid values: #{Enum.join(@valid_type_values, ", ")}"
        | errors
      ]
    end
  end

  defp validate_field_value_type("type", value, _operator, prefix, errors) do
    if value in @valid_type_values do
      errors
    else
      [
        "#{prefix}: invalid type value '#{value}'. Valid values: #{Enum.join(@valid_type_values, ", ")}"
        | errors
      ]
    end
  end

  defp validate_field_value_type(field, value, operator, prefix, errors)
       when field in @string_fields and operator in ["in", "not_in"] do
    # For list operators, check all values are strings - operator used in guard, prefix used in error
    _ = operator

    invalid_values =
      value
      |> List.wrap()
      |> Enum.reject(&is_binary/1)

    if invalid_values == [] do
      errors
    else
      ["#{prefix}: #{field} requires text values, got: #{inspect(invalid_values)}" | errors]
    end
  end

  defp validate_field_value_type(field, value, _operator, prefix, errors)
       when field in @string_fields do
    if is_binary(value) do
      errors
    else
      ["#{prefix}: #{field} requires a text value, got: #{inspect(value)}" | errors]
    end
  end

  defp validate_field_value_type(field, value, "between", prefix, errors)
       when field in @numeric_fields do
    case value do
      [min, max] when is_number(min) and is_number(max) ->
        errors

      _ ->
        ["#{prefix}: #{field} between requires two numeric values" | errors]
    end
  end

  defp validate_field_value_type(field, value, operator, prefix, errors)
       when field in @numeric_fields and operator in ["in", "not_in"] do
    invalid_values =
      value
      |> List.wrap()
      |> Enum.reject(&is_number/1)

    if invalid_values == [] do
      errors
    else
      ["#{prefix}: #{field} requires numeric values, got: #{inspect(invalid_values)}" | errors]
    end
  end

  defp validate_field_value_type(field, value, _operator, prefix, errors)
       when field in @numeric_fields do
    if is_number(value) do
      errors
    else
      ["#{prefix}: #{field} requires a numeric value, got: #{inspect(value)}" | errors]
    end
  end

  defp validate_field_value_type(field, value, _operator, prefix, errors)
       when field in @boolean_fields do
    if is_boolean(value) do
      errors
    else
      ["#{prefix}: #{field} requires true or false, got: #{inspect(value)}" | errors]
    end
  end

  # Default: no additional validation for other fields
  defp validate_field_value_type(_field, _value, _operator, _prefix, errors), do: errors

  defp validate_sort(sort) do
    errors = []

    errors =
      case Map.get(sort, "field") do
        nil -> errors
        field when field in @valid_sort_fields -> errors
        field -> ["sort.field '#{field}' is invalid" | errors]
      end

    errors =
      case Map.get(sort, "direction") do
        nil -> errors
        dir when dir in @valid_sort_directions -> errors
        dir -> ["sort.direction '#{dir}' is invalid" | errors]
      end

    errors
  end

  defp build_query(rules) do
    match_type = Map.get(rules, "match_type", "all")
    conditions = Map.get(rules, "conditions", [])

    base_query = from(m in MediaItem)

    if Enum.empty?(conditions) do
      base_query
    else
      Enum.reduce(conditions, base_query, fn condition, query ->
        apply_condition(query, condition, match_type)
      end)
    end
  end

  # Applied right after `build_query/1` while `MediaItem` is still the query's
  # only binding, so `Restrictions.apply/2` attaches its `where` clauses there.
  defp maybe_apply_scope(query, nil), do: query
  defp maybe_apply_scope(query, %Scope{} = scope), do: Restrictions.apply(query, scope)

  defp apply_condition(query, condition, match_type) do
    field = Map.get(condition, "field")
    operator = Map.get(condition, "operator")
    value = Map.get(condition, "value")

    dynamic_condition = build_dynamic(field, operator, value)

    case match_type do
      "any" ->
        from(m in query, or_where: ^dynamic_condition)

      _ ->
        # "all" - AND conditions (default)
        from(m in query, where: ^dynamic_condition)
    end
  end

  # Standard field conditions
  defp build_dynamic("category", "eq", value), do: dynamic([m], m.category == ^value)
  defp build_dynamic("category", "in", values), do: dynamic([m], m.category in ^values)
  defp build_dynamic("category", "not_in", values), do: dynamic([m], m.category not in ^values)

  defp build_dynamic("type", "eq", value), do: dynamic([m], m.type == ^value)
  defp build_dynamic("type", "in", values), do: dynamic([m], m.type in ^values)
  defp build_dynamic("type", "not_in", values), do: dynamic([m], m.type not in ^values)

  defp build_dynamic("year", "eq", value), do: dynamic([m], m.year == ^value)
  defp build_dynamic("year", "gt", value), do: dynamic([m], m.year > ^value)
  defp build_dynamic("year", "gte", value), do: dynamic([m], m.year >= ^value)
  defp build_dynamic("year", "lt", value), do: dynamic([m], m.year < ^value)
  defp build_dynamic("year", "lte", value), do: dynamic([m], m.year <= ^value)

  defp build_dynamic("year", "between", [min, max]),
    do: dynamic([m], m.year >= ^min and m.year <= ^max)

  defp build_dynamic("year", "in", values), do: dynamic([m], m.year in ^values)

  defp build_dynamic("title", "eq", value), do: dynamic([m], m.title == ^value)

  defp build_dynamic("title", "contains", value) do
    # SQLite doesn't support ilike, use LIKE with LOWER() for case-insensitive search
    pattern = "%#{String.downcase(value)}%"
    dynamic([m], fragment("LOWER(title) LIKE ?", ^pattern))
  end

  defp build_dynamic("monitored", "eq", true), do: dynamic([m], m.monitored == true)
  defp build_dynamic("monitored", "eq", false), do: dynamic([m], m.monitored == false)

  # Metadata fields - adapter-aware JSON extraction
  defp build_dynamic("metadata.vote_average", op, value) when op in ~w(gte gt lte lt eq) do
    json_val = json_extract_numeric(:metadata, "$.vote_average")

    case op do
      "gte" -> dynamic([m], ^json_val >= ^value)
      "gt" -> dynamic([m], ^json_val > ^value)
      "lte" -> dynamic([m], ^json_val <= ^value)
      "lt" -> dynamic([m], ^json_val < ^value)
      "eq" -> dynamic([m], ^json_val == ^value)
    end
  end

  defp build_dynamic("metadata.vote_average", "between", [min, max]) do
    json_val = json_extract_numeric(:metadata, "$.vote_average")
    dynamic([m], ^json_val >= ^min and ^json_val <= ^max)
  end

  defp build_dynamic("metadata.genres", "contains", value) do
    # JSON array search using LIKE on the JSON string representation
    pattern = "%\"#{value}\"%"
    json_val = json_extract_dynamic(:metadata, "$.genres")
    dynamic([m], like(^json_val, ^pattern))
  end

  defp build_dynamic("metadata.genres", "contains_any", values) when is_list(values) do
    json_val = json_extract_dynamic(:metadata, "$.genres")

    Enum.reduce(values, dynamic([m], false), fn value, acc ->
      pattern = "%\"#{value}\"%"
      dynamic([m], ^acc or like(^json_val, ^pattern))
    end)
  end

  defp build_dynamic("metadata.original_language", "eq", value) do
    dynamic([m], ^DB.json_equals(:metadata, "$.original_language", value))
  end

  defp build_dynamic("metadata.original_language", "in", values) when is_list(values) do
    json_val = json_extract_dynamic(:metadata, "$.original_language")

    Enum.reduce(values, dynamic([m], false), fn value, acc ->
      dynamic([m], ^acc or ^json_val == ^value)
    end)
  end

  defp build_dynamic("metadata.status", "eq", value) do
    dynamic([m], ^DB.json_equals(:metadata, "$.status", value))
  end

  defp build_dynamic("metadata.status", "in", values) when is_list(values) do
    json_val = json_extract_dynamic(:metadata, "$.status")

    Enum.reduce(values, dynamic([m], false), fn value, acc ->
      dynamic([m], ^acc or ^json_val == ^value)
    end)
  end

  defp build_dynamic("inserted_at", "gte", value) do
    case parse_datetime(value) do
      {:ok, datetime} -> dynamic([m], m.inserted_at >= ^datetime)
      _ -> dynamic([m], true)
    end
  end

  defp build_dynamic("inserted_at", "lte", value) do
    case parse_datetime(value) do
      {:ok, datetime} -> dynamic([m], m.inserted_at <= ^datetime)
      _ -> dynamic([m], true)
    end
  end

  defp build_dynamic("inserted_at", "gt", value) do
    case parse_datetime(value) do
      {:ok, datetime} -> dynamic([m], m.inserted_at > ^datetime)
      _ -> dynamic([m], true)
    end
  end

  defp build_dynamic("inserted_at", "lt", value) do
    case parse_datetime(value) do
      {:ok, datetime} -> dynamic([m], m.inserted_at < ^datetime)
      _ -> dynamic([m], true)
    end
  end

  # Fallback for unknown conditions
  defp build_dynamic(_field, _operator, _value), do: dynamic([m], true)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_), do: :error

  defp apply_sort(query, rules) do
    case Map.get(rules, "sort") do
      %{"field" => field, "direction" => direction} ->
        do_apply_sort(query, field, direction)

      %{"field" => field} ->
        do_apply_sort(query, field, "asc")

      _ ->
        query
    end
  end

  defp do_apply_sort(query, "title", "asc"), do: order_by(query, [m], asc: m.title)
  defp do_apply_sort(query, "title", "desc"), do: order_by(query, [m], desc: m.title)
  defp do_apply_sort(query, "year", "asc"), do: order_by(query, [m], asc: m.year)
  defp do_apply_sort(query, "year", "desc"), do: order_by(query, [m], desc: m.year)
  defp do_apply_sort(query, "added_date", "asc"), do: order_by(query, [m], asc: m.inserted_at)
  defp do_apply_sort(query, "added_date", "desc"), do: order_by(query, [m], desc: m.inserted_at)

  defp do_apply_sort(query, "rating", direction) do
    json_val = json_extract_numeric(:metadata, "$.vote_average")

    case direction do
      "asc" -> order_by(query, [m], asc: ^json_val)
      "desc" -> order_by(query, [m], desc: ^json_val)
    end
  end

  defp do_apply_sort(query, _, _), do: query

  defp apply_limit(query, rules, opts) do
    # opts[:limit] takes precedence over rules limit
    limit_val =
      case Keyword.get(opts, :limit) do
        nil -> Map.get(rules, "limit")
        opt_limit -> opt_limit
      end

    case limit_val do
      limit when is_integer(limit) and limit > 0 -> limit(query, ^limit)
      _ -> query
    end
  end

  defp apply_offset(query, opts) do
    case Keyword.get(opts, :offset) do
      offset when is_integer(offset) and offset > 0 -> offset(query, ^offset)
      _ -> query
    end
  end

  # Returns a dynamic expression for extracting a JSON value, adapter-aware
  defp json_extract_dynamic(field_atom, path) do
    if DB.postgres?() do
      pg_key = DB.sqlite_path_to_postgres_key(path)
      dynamic([q], fragment("?::jsonb ->> ?", field(q, ^field_atom), ^pg_key))
    else
      dynamic([q], fragment("json_extract(?, ?)", field(q, ^field_atom), ^path))
    end
  end

  # Returns a dynamic expression for extracting a numeric JSON value.
  # On PostgreSQL, casts the result to numeric since ->> returns text.
  defp json_extract_numeric(field_atom, path) do
    if DB.postgres?() do
      pg_key = DB.sqlite_path_to_postgres_key(path)
      dynamic([q], fragment("(?::jsonb ->> ?)::numeric", field(q, ^field_atom), ^pg_key))
    else
      dynamic([q], fragment("json_extract(?, ?)", field(q, ^field_atom), ^path))
    end
  end
end
