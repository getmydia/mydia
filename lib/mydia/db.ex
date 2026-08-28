defmodule Mydia.DB do
  @moduledoc """
  Database abstraction layer for database-agnostic operations.

  This module provides helper functions and macros that abstract away differences
  between SQLite and PostgreSQL, allowing the application code to remain
  database-agnostic.

  ## Compile-time Selection

  This module uses macros that expand at compile time based on the configured
  database adapter. The appropriate SQL syntax for the target database is
  selected during compilation.

  Usage:

      import Mydia.DB

      from d in Download,
        where: json_extract(d.metadata, "$.download_client") == ^client_name

      from j in Job,
        select: avg_timestamp_diff_seconds(j.completed_at, j.attempted_at)

  ## Supported Databases

  - SQLite (via Ecto.Adapters.SQLite3) - Default
  - PostgreSQL (via Ecto.Adapters.Postgres) - Configurable

  ## Configuration

  The database adapter is configured at compile time via the `DATABASE_TYPE`
  environment variable, which sets `:database_adapter` in config/config.exs:

      # Set during compilation (e.g., Docker build)
      DATABASE_TYPE=postgres mix compile

  Different Docker images are built for each database type, with the appropriate
  adapter compiled into each release.
  """

  import Ecto.Query

  # Capture the database adapter at compile time for use in macros
  @database_adapter Application.compile_env(:mydia, :database_adapter, Ecto.Adapters.SQLite3)

  @doc """
  Returns the current database adapter type.

  ## Examples

      iex> Mydia.DB.adapter_type()
      :sqlite

  ## Returns

  - `:sqlite` - When using SQLite (default)
  - `:postgres` - When using PostgreSQL
  """
  @spec adapter_type() :: :sqlite | :postgres
  def adapter_type do
    case Application.get_env(:mydia, :database_adapter, Ecto.Adapters.SQLite3) do
      Ecto.Adapters.Postgres -> :postgres
      _ -> :sqlite
    end
  end

  @doc """
  Returns true if using SQLite adapter.

  ## Examples

      iex> Mydia.DB.sqlite?()
      true
  """
  @spec sqlite?() :: boolean()
  def sqlite? do
    Application.get_env(:mydia, :database_adapter, Ecto.Adapters.SQLite3) == Ecto.Adapters.SQLite3
  end

  @doc """
  Returns true if using PostgreSQL adapter.

  ## Examples

      iex> Mydia.DB.postgres?()
      false
  """
  @spec postgres?() :: boolean()
  def postgres? do
    Application.get_env(:mydia, :database_adapter, Ecto.Adapters.SQLite3) ==
      Ecto.Adapters.Postgres
  end

  # ===========================================================================
  # Runtime Functions (Recommended)
  #
  # These functions return Ecto.Query.dynamic/2 expressions that are evaluated
  # at runtime, allowing database switching without recompilation.
  # ===========================================================================

  @doc """
  Runtime-switchable JSON string equality check.

  Returns a dynamic expression that compares a JSON field value to a string.
  The database-specific SQL is selected at runtime based on the configured adapter.

  ## Parameters

  - `field_atom` - The field name as an atom (e.g., `:metadata`)
  - `path` - The JSON path string using SQLite `$.key` syntax
  - `value` - The value to compare against

  ## Examples

      from d in Download,
        where: ^Mydia.DB.json_equals(:metadata, "$.download_client", "qbittorrent")

      # With a variable:
      client = "qbittorrent"
      from d in Download,
        where: ^Mydia.DB.json_equals(:metadata, "$.download_client", client)

  ## Database-specific behavior

  - **SQLite**: `json_extract(field, path) = value`
  - **PostgreSQL**: `field ->> 'key' = value`
  """
  @spec json_equals(atom(), String.t(), String.t()) :: Ecto.Query.dynamic_expr()
  def json_equals(field_atom, path, value)
      when is_atom(field_atom) and is_binary(path) and is_binary(value) do
    if postgres?() do
      pg_key = sqlite_path_to_postgres_key(path)
      dynamic([q], fragment("?::jsonb ->> ?", field(q, ^field_atom), ^pg_key) == ^value)
    else
      dynamic([q], fragment("json_extract(?, ?)", field(q, ^field_atom), ^path) == ^value)
    end
  end

  @doc """
  Runtime-switchable JSON integer equality check.

  Returns a dynamic expression that compares a JSON field value to an integer.
  The field value is cast to integer before comparison.

  ## Parameters

  - `field_atom` - The field name as an atom (e.g., `:metadata`)
  - `path` - The JSON path string using SQLite `$.key` syntax
  - `value` - The integer value to compare against

  ## Examples

      from d in Download,
        where: ^Mydia.DB.json_integer_equals(:metadata, "$.season_number", 3)

  ## Database-specific behavior

  - **SQLite**: `CAST(json_extract(field, path) AS INTEGER) = value`
  - **PostgreSQL**: `(field ->> 'key')::integer = value`
  """
  @spec json_integer_equals(atom(), String.t(), integer()) :: Ecto.Query.dynamic_expr()
  def json_integer_equals(field_atom, path, value)
      when is_atom(field_atom) and is_binary(path) and is_integer(value) do
    if postgres?() do
      pg_key = sqlite_path_to_postgres_key(path)

      dynamic(
        [q],
        fragment("(?::jsonb ->> ?)::integer", field(q, ^field_atom), ^pg_key) == ^value
      )
    else
      dynamic(
        [q],
        fragment("CAST(json_extract(?, ?) AS INTEGER)", field(q, ^field_atom), ^path) == ^value
      )
    end
  end

  @doc """
  Runtime-switchable JSON boolean check (truthy).

  Returns a dynamic expression that checks if a JSON field value is truthy.
  Handles the differences between how SQLite and PostgreSQL store booleans.

  ## Parameters

  - `field_atom` - The field name as an atom (e.g., `:metadata`)
  - `path` - The JSON path string using SQLite `$.key` syntax

  ## Examples

      from d in Download,
        where: ^Mydia.DB.json_is_true(:metadata, "$.season_pack")

  ## Database-specific behavior

  - **SQLite**: True if value is `1` or string `'true'`
  - **PostgreSQL**: `(field ->> 'key')::boolean`
  """
  @spec json_is_true(atom(), String.t()) :: Ecto.Query.dynamic_expr()
  def json_is_true(field_atom, path) when is_atom(field_atom) and is_binary(path) do
    if postgres?() do
      pg_key = sqlite_path_to_postgres_key(path)
      dynamic([q], fragment("(?::jsonb ->> ?)::boolean", field(q, ^field_atom), ^pg_key))
    else
      # SQLite json_extract returns 1 for JSON boolean true, or might store "true" string
      dynamic(
        [q],
        fragment("json_extract(?, ?) = 1", field(q, ^field_atom), ^path) or
          fragment("json_extract(?, ?) = 'true'", field(q, ^field_atom), ^path)
      )
    end
  end

  @doc """
  Runtime-switchable JSON not null check.

  Returns a dynamic expression that checks if a JSON field has a non-null value
  at the given path.

  ## Parameters

  - `field_atom` - The field name as an atom (e.g., `:metadata`)
  - `path` - The JSON path string using SQLite `$.key` syntax

  ## Examples

      from m in MediaItem,
        where: ^Mydia.DB.json_is_not_null(:metadata, "$.release_date")

  ## Database-specific behavior

  - **SQLite**: `json_extract(field, path) IS NOT NULL`
  - **PostgreSQL**: `field ->> 'key' IS NOT NULL`
  """
  @spec json_is_not_null(atom(), String.t()) :: Ecto.Query.dynamic_expr()
  def json_is_not_null(field_atom, path) when is_atom(field_atom) and is_binary(path) do
    if postgres?() do
      pg_key = sqlite_path_to_postgres_key(path)
      dynamic([q], not is_nil(fragment("?::jsonb ->> ?", field(q, ^field_atom), ^pg_key)))
    else
      dynamic([q], not is_nil(fragment("json_extract(?, ?)", field(q, ^field_atom), ^path)))
    end
  end

  @doc """
  Runtime-switchable JSON date range check, both bounds inclusive.

  Dates are stored through `Jason.encode!` as ISO-8601 strings, which sort
  lexicographically, so a string comparison answers a date range correctly on
  both adapters without any date parsing in SQL.

  ## Parameters

  - `field_atom` - The field name as an atom (e.g. `:metadata`)
  - `path` - The JSON path string using SQLite `$.key` syntax
  - `start_date` - Earliest date to match, inclusive
  - `end_date` - Latest date to match, inclusive

  ## Examples

      from m in MediaItem,
        where: ^Mydia.DB.json_date_between(:metadata, "$.release_date", ~D[2026-08-01], ~D[2026-08-31])

  ## Database-specific behavior

  - **SQLite**: `json_extract(field, path) BETWEEN ? AND ?`
  - **PostgreSQL**: `field ->> 'key' BETWEEN ? AND ?`
  """
  @spec json_date_between(atom(), String.t(), Date.t(), Date.t()) :: Ecto.Query.dynamic_expr()
  def json_date_between(field_atom, path, %Date{} = start_date, %Date{} = end_date)
      when is_atom(field_atom) and is_binary(path) do
    start_string = Date.to_iso8601(start_date)
    end_string = Date.to_iso8601(end_date)

    if postgres?() do
      pg_key = sqlite_path_to_postgres_key(path)

      dynamic(
        [q],
        fragment("?::jsonb ->> ?", field(q, ^field_atom), ^pg_key) >= ^start_string and
          fragment("?::jsonb ->> ?", field(q, ^field_atom), ^pg_key) <= ^end_string
      )
    else
      dynamic(
        [q],
        fragment("json_extract(?, ?)", field(q, ^field_atom), ^path) >= ^start_string and
          fragment("json_extract(?, ?)", field(q, ^field_atom), ^path) <= ^end_string
      )
    end
  end

  @doc """
  Runtime-switchable JSON null check.

  Returns a dynamic expression that checks if a JSON field has a null value
  at the given path or the path doesn't exist.

  ## Parameters

  - `field_atom` - The field name as an atom (e.g., `:metadata`)
  - `path` - The JSON path string using SQLite `$.key` syntax

  ## Examples

      from m in MediaItem,
        where: ^Mydia.DB.json_is_null(:metadata, "$.optional_field")

  ## Database-specific behavior

  - **SQLite**: `json_extract(field, path) IS NULL`
  - **PostgreSQL**: `field ->> 'key' IS NULL`
  """
  @spec json_is_null(atom(), String.t()) :: Ecto.Query.dynamic_expr()
  def json_is_null(field_atom, path) when is_atom(field_atom) and is_binary(path) do
    if postgres?() do
      pg_key = sqlite_path_to_postgres_key(path)
      dynamic([q], is_nil(fragment("?::jsonb ->> ?", field(q, ^field_atom), ^pg_key)))
    else
      dynamic([q], is_nil(fragment("json_extract(?, ?)", field(q, ^field_atom), ^path)))
    end
  end

  # ===========================================================================
  # Compile-time Macros
  #
  # These macros expand at compile time based on the configured database adapter.
  # The adapter is selected during compilation via the DATABASE_TYPE environment
  # variable, which sets :database_adapter in config/config.exs.
  # ===========================================================================

  @doc """
  Extracts a value from a JSON field at the given path.

  This is a macro that generates the appropriate SQL fragment based on the
  current database adapter.

  ## Parameters

  - `field` - The JSON field expression (e.g., `d.metadata`)
  - `path` - The JSON path string (SQLite `$.key` syntax)

  ## Examples

      from d in Download,
        where: json_extract(d.metadata, "$.download_client") == ^client_name

      from f in MediaFile,
        where: json_extract(f.metadata, "$.download_client_id") == ^client_id

  ## Database-specific behavior

  - **SQLite**: Uses `json_extract(field, path)`
  - **PostgreSQL**: Uses `field->>'key'`
  """
  defmacro json_extract(field, path) do
    if postgres_configured?() do
      pg_key = sqlite_path_to_postgres_key(path)

      quote do
        fragment("?::jsonb ->> ?", unquote(field), unquote(pg_key))
      end
    else
      quote do
        fragment("json_extract(?, ?)", unquote(field), unquote(path))
      end
    end
  end

  @doc """
  Extracts a value from a JSON field and casts it to an integer.

  ## Parameters

  - `field` - The JSON field expression (e.g., `d.metadata`)
  - `path` - The JSON path string (SQLite `$.key` syntax)

  ## Examples

      from d in Download,
        where: json_extract_integer(d.metadata, "$.season_number") == ^season_number

  ## Database-specific behavior

  - **SQLite**: Uses `CAST(json_extract(field, path) AS INTEGER)`
  - **PostgreSQL**: Uses `(field->>'key')::integer`
  """
  defmacro json_extract_integer(field, path) do
    if postgres_configured?() do
      pg_key = sqlite_path_to_postgres_key(path)

      quote do
        fragment("(?::jsonb ->> ?)::integer", unquote(field), unquote(pg_key))
      end
    else
      quote do
        fragment("CAST(json_extract(?, ?) AS INTEGER)", unquote(field), unquote(path))
      end
    end
  end

  @doc """
  Extracts a boolean value from a JSON field.

  Handles the differences between how SQLite and PostgreSQL store booleans in JSON:
  - SQLite stores JSON booleans as `1` or `0` (or sometimes string `"true"`/`"false"`)
  - PostgreSQL stores JSON booleans as `true` or `false`

  ## Parameters

  - `field` - The JSON field expression (e.g., `d.metadata`)
  - `path` - The JSON path string (SQLite `$.key` syntax)

  ## Examples

      from d in Download,
        where: json_extract_boolean(d.metadata, "$.season_pack")

  ## Database-specific behavior

  - **SQLite**: Returns true if value is `1` or `'true'`
  - **PostgreSQL**: Uses `(field->>'key')::boolean`

  ## Returns

  An expression that evaluates to a boolean.
  """
  defmacro json_extract_boolean(field, path) do
    if postgres_configured?() do
      pg_key = sqlite_path_to_postgres_key(path)

      quote do
        fragment("(?::jsonb ->> ?)::boolean", unquote(field), unquote(pg_key))
      end
    else
      quote do
        # SQLite json_extract returns 1 for JSON boolean true, or might store "true" string
        fragment("json_extract(?, ?) = 1", unquote(field), unquote(path)) or
          fragment("json_extract(?, ?) = 'true'", unquote(field), unquote(path))
      end
    end
  end

  @doc """
  Checks if a JSON field has a non-null value at the given path.

  ## Parameters

  - `field` - The JSON field expression (e.g., `m.metadata`)
  - `path` - The JSON path string (SQLite `$.key` syntax)

  ## Examples

      from m in MediaItem,
        where: json_not_null(m.metadata, "$.release_date")

  ## Database-specific behavior

  - **SQLite**: Uses `json_extract(field, path) IS NOT NULL`
  - **PostgreSQL**: Uses `field->>'key' IS NOT NULL`
  """
  defmacro json_not_null(field, path) do
    if postgres_configured?() do
      pg_key = sqlite_path_to_postgres_key(path)

      quote do
        not is_nil(fragment("?::jsonb ->> ?", unquote(field), unquote(pg_key)))
      end
    else
      quote do
        not is_nil(fragment("json_extract(?, ?)", unquote(field), unquote(path)))
      end
    end
  end

  @doc """
  Casts an expression to a floating-point number (REAL).

  ## Parameters

  - `expr` - The expression to cast

  ## Examples

      from j in Job,
        select: cast_to_real(j.duration)

  ## Database-specific behavior

  - **SQLite**: Uses `CAST(expr AS REAL)`
  - **PostgreSQL**: Uses `expr::float`
  """
  defmacro cast_to_real(expr) do
    if postgres_configured?() do
      quote do
        fragment("?::float", unquote(expr))
      end
    else
      quote do
        fragment("CAST(? AS REAL)", unquote(expr))
      end
    end
  end

  @doc """
  Casts an expression to an integer.

  ## Parameters

  - `expr` - The expression to cast

  ## Examples

      from m in MediaItem,
        select: cast_to_integer(m.year_string)

  ## Database-specific behavior

  - **SQLite**: Uses `CAST(expr AS INTEGER)`
  - **PostgreSQL**: Uses `expr::integer`
  """
  defmacro cast_to_integer(expr) do
    if postgres_configured?() do
      quote do
        fragment("?::integer", unquote(expr))
      end
    else
      quote do
        fragment("CAST(? AS INTEGER)", unquote(expr))
      end
    end
  end

  @doc """
  Calculates the average difference in seconds between two timestamp fields.

  This is a macro that generates the appropriate SQL for averaging timestamp
  differences based on the configured database adapter.

  ## Parameters

  - `end_field` - The ending timestamp field (e.g., `j.completed_at`)
  - `start_field` - The starting timestamp field (e.g., `j.attempted_at`)

  ## Examples

      from j in Job,
        where: j.state == "completed",
        select: avg_timestamp_diff_seconds(j.completed_at, j.attempted_at)

  ## Database-specific behavior

  - **SQLite**: Uses `AVG((julianday(end) - julianday(start)) * 86400)`
  - **PostgreSQL**: Uses `AVG(EXTRACT(EPOCH FROM (end - start)))`
  """
  defmacro avg_timestamp_diff_seconds(end_field, start_field) do
    if postgres_configured?() do
      quote do
        fragment(
          "AVG(EXTRACT(EPOCH FROM (? - ?)))",
          unquote(end_field),
          unquote(start_field)
        )
      end
    else
      quote do
        # SQLite: use julianday() to properly calculate time difference
        # julianday returns days, multiply by 86400 to get seconds
        fragment(
          "AVG((julianday(?) - julianday(?)) * 86400)",
          unquote(end_field),
          unquote(start_field)
        )
      end
    end
  end

  @doc """
  Calculates the difference in seconds between two timestamp fields.

  This is a macro that generates the appropriate SQL for timestamp differences
  based on the configured database adapter.

  ## Parameters

  - `end_field` - The ending timestamp field (e.g., `j.completed_at`)
  - `start_field` - The starting timestamp field (e.g., `j.attempted_at`)

  ## Examples

      from j in Job,
        select: timestamp_diff_seconds(j.completed_at, j.attempted_at)

  ## Database-specific behavior

  - **SQLite**: Uses `(julianday(end) - julianday(start)) * 86400`
  - **PostgreSQL**: Uses `EXTRACT(EPOCH FROM (end - start))`
  """
  defmacro timestamp_diff_seconds(end_field, start_field) do
    if postgres_configured?() do
      quote do
        fragment("EXTRACT(EPOCH FROM (? - ?))", unquote(end_field), unquote(start_field))
      end
    else
      quote do
        # SQLite: use julianday() to properly calculate time difference
        # julianday returns days, multiply by 86400 to get seconds
        fragment(
          "(julianday(?) - julianday(?)) * 86400",
          unquote(end_field),
          unquote(start_field)
        )
      end
    end
  end

  @doc """
  Checks if a subquery exists and returns a boolean.

  This generates a CASE WHEN EXISTS(...) THEN true ELSE false END expression.

  ## Parameters

  - `subquery` - A raw SQL string for the subquery
  - `binding` - The value to bind in the subquery

  ## Examples

      # Check if media files exist for an episode
      from e in Episode,
        select: %{
          id: e.id,
          has_files: exists_check("SELECT 1 FROM media_files WHERE episode_id = ?", e.id)
        }

  ## Note

  Both SQLite and PostgreSQL support standard SQL EXISTS syntax.
  """
  defmacro exists_check(subquery, binding) do
    sql = "CASE WHEN EXISTS(#{subquery}) THEN true ELSE false END"

    quote do
      fragment(unquote(sql), unquote(binding))
    end
  end

  # Private helpers (used at compile time by macros)

  @doc false
  def sqlite_path_to_postgres_key(path) when is_binary(path) do
    path
    |> String.trim_leading("$.")
    |> String.trim_leading("$")
  end

  # Returns true if PostgreSQL is configured (used at macro expansion time)
  @doc false
  defp postgres_configured? do
    @database_adapter == Ecto.Adapters.Postgres
  end
end
