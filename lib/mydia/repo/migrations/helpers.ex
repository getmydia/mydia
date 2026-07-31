defmodule Mydia.Repo.Migrations.Helpers do
  @moduledoc """
  Database-agnostic helpers for Ecto migrations.

  This module provides helper functions that abstract away differences between
  SQLite and PostgreSQL for migration operations that aren't supported by
  standard Ecto DSL.

  ## Why This Module Exists

  SQLite has limited ALTER TABLE support compared to PostgreSQL:
  - Cannot modify column nullability directly
  - Cannot change column types directly
  - Cannot modify CHECK constraints

  For these operations, SQLite requires table recreation (rename -> create new -> copy -> drop old).
  PostgreSQL supports direct ALTER TABLE statements.

  ## Usage in Migrations

      defmodule MyApp.Repo.Migrations.MakeColumnNullable do
        use Ecto.Migration
        import Mydia.Repo.Migrations.Helpers

        def change do
          modify_column_null(:my_table, :my_column, true)
        end
      end

  ## Available Functions

  - `postgres?/0` - Returns true if using PostgreSQL
  - `sqlite?/0` - Returns true if using SQLite
  - `modify_column_null/3` - Make a column nullable or not nullable
  - `execute_update/2` - Execute an UPDATE with database-agnostic booleans
  """

  import Ecto.Migration

  @doc """
  Returns true if using PostgreSQL adapter.

  Uses the repo's adapter configuration to determine the database type.
  """
  @spec postgres?() :: boolean()
  def postgres? do
    # Check the adapter configured for the repo
    # During migrations, we can check the repo config
    adapter = repo().__adapter__()
    adapter == Ecto.Adapters.Postgres
  end

  @doc """
  Returns true if using SQLite adapter.
  """
  @spec sqlite?() :: boolean()
  def sqlite? do
    adapter = repo().__adapter__()
    adapter == Ecto.Adapters.SQLite3
  end

  @doc """
  Make a column nullable or not nullable.

  This handles the database-specific differences:
  - PostgreSQL: Uses ALTER COLUMN SET/DROP NOT NULL
  - SQLite: Not directly supported, raises an error with guidance

  ## Parameters

  - `table_name` - The table name as an atom
  - `column_name` - The column name as an atom
  - `nullable` - `true` to make nullable, `false` to make NOT NULL

  ## Examples

      # Make column nullable
      modify_column_null(:users, :email, true)

      # Make column NOT NULL
      modify_column_null(:users, :email, false)

  ## Note for SQLite

  SQLite doesn't support ALTER COLUMN. For complex schema changes on SQLite,
  use `recreate_table_with_changes/3` instead, which handles the full
  table recreation workflow.
  """
  @spec modify_column_null(atom(), atom(), boolean()) :: :ok
  def modify_column_null(table_name, column_name, nullable) do
    if postgres?() do
      if nullable do
        execute(
          "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} DROP NOT NULL",
          "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET NOT NULL"
        )
      else
        execute(
          "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET NOT NULL",
          "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} DROP NOT NULL"
        )
      end
    else
      raise """
      SQLite does not support ALTER COLUMN for nullability changes.

      For SQLite compatibility, you have two options:

      1. Use Ecto DSL `alter table` which handles this for simple cases:

          alter table(:#{table_name}) do
            modify :#{column_name}, :string, null: #{nullable}
          end

      2. For complex cases, manually recreate the table:
         - Rename original table
         - Create new table with desired schema
         - Copy data
         - Drop old table
         - Recreate indexes

      See existing migrations for examples of table recreation pattern.
      """
    end
  end

  @doc """
  Change a column's type.

  ## Parameters

  - `table_name` - The table name as an atom
  - `column_name` - The column name as an atom
  - `new_type` - The new column type
  - `opts` - Options including `:using` for PostgreSQL type conversion

  ## Examples

      # Change column from integer to string
      modify_column_type(:events, :actor_id, :string)

      # With explicit cast for PostgreSQL
      modify_column_type(:events, :actor_id, :string, using: "actor_id::text")

  ## Note for SQLite

  SQLite doesn't support ALTER COLUMN TYPE. For type changes on SQLite,
  you must recreate the table.
  """
  @spec modify_column_type(atom(), atom(), atom(), keyword()) :: :ok
  def modify_column_type(table_name, column_name, new_type, opts \\ []) do
    if postgres?() do
      using_clause = if opts[:using], do: " USING #{opts[:using]}", else: ""

      execute(
        "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} TYPE #{pg_type(new_type)}#{using_clause}",
        # Rollback would need the old type - this is a one-way operation
        "SELECT 1"
      )
    else
      raise """
      SQLite does not support ALTER COLUMN TYPE.

      For SQLite compatibility, you must recreate the table:
      1. Rename original table to #{table_name}_old
      2. Create new table with updated column type
      3. Copy data from old table
      4. Drop old table
      5. Recreate indexes

      See existing migrations for examples of this pattern.
      """
    end
  end

  @doc """
  Execute an UPDATE statement with database-agnostic boolean values.

  SQLite uses 1/0 for booleans, PostgreSQL uses true/false.

  ## Parameters

  - `table_name` - The table name as an atom or string
  - `set_clause` - A keyword list of column => value pairs

  ## Examples

      # Set a boolean column to true
      execute_update(:library_paths, from_env: true)

      # Set multiple columns
      execute_update(:users, active: true, verified: false)
  """
  @spec execute_update(atom() | String.t(), keyword()) :: :ok
  def execute_update(table_name, set_clause) do
    set_parts =
      Enum.map(set_clause, fn {column, value} ->
        db_value = to_db_value(value)
        "#{column} = #{db_value}"
      end)

    set_string = Enum.join(set_parts, ", ")

    execute("UPDATE #{table_name} SET #{set_string}")
  end

  @doc """
  Execute an UPDATE statement with a WHERE clause and database-agnostic values.

  ## Parameters

  - `table_name` - The table name
  - `set_clause` - Keyword list of column => value pairs to SET
  - `where_clause` - Keyword list of column => value pairs for WHERE (AND conditions)

  ## Examples

      execute_update_where(:users, [active: false], [role: "guest"])
  """
  @spec execute_update_where(atom() | String.t(), keyword(), keyword()) :: :ok
  def execute_update_where(table_name, set_clause, where_clause) do
    set_parts =
      Enum.map(set_clause, fn {column, value} ->
        "#{column} = #{to_db_value(value)}"
      end)

    where_parts =
      Enum.map(where_clause, fn {column, value} ->
        "#{column} = #{to_db_value(value)}"
      end)

    set_string = Enum.join(set_parts, ", ")
    where_string = Enum.join(where_parts, " AND ")

    execute("UPDATE #{table_name} SET #{set_string} WHERE #{where_string}")
  end

  @doc """
  Convert an Elixir value to a database-appropriate SQL literal.

  - Booleans: SQLite uses 1/0, PostgreSQL uses TRUE/FALSE
  - Strings: Quoted with single quotes
  - nil: NULL
  - Numbers: As-is
  """
  @spec to_db_value(any()) :: String.t()
  def to_db_value(true), do: if(postgres?(), do: "TRUE", else: "1")
  def to_db_value(false), do: if(postgres?(), do: "FALSE", else: "0")
  def to_db_value(nil), do: "NULL"
  def to_db_value(value) when is_binary(value), do: "'#{escape_sql_string(value)}'"
  def to_db_value(value) when is_number(value), do: to_string(value)
  def to_db_value(value), do: "'#{escape_sql_string(to_string(value))}'"

  # Escape single quotes in SQL strings
  defp escape_sql_string(str), do: String.replace(str, "'", "''")

  # ============================================================================
  # Database-Specific Execution
  # ============================================================================

  @doc """
  Execute database-specific code.

  Use this when you need completely different logic for each database,
  such as when SQLite requires table recreation but PostgreSQL can skip
  the operation entirely (or use ALTER statements).

  ## Options

  - `:sqlite` - Function to execute for SQLite (optional)
  - `:postgres` - Function to execute for PostgreSQL (optional)

  ## Examples

      # Different implementations for each database
      for_database(
        sqlite: fn ->
          # SQLite-specific code
        end,
        postgres: fn ->
          # PostgreSQL-specific code (or omit for no-op)
        end
      )

      # SQLite-only operation (no-op on PostgreSQL)
      for_database(
        sqlite: fn ->
          execute "..."
        end
      )
  """
  def for_database(opts) do
    cond do
      postgres?() -> if fun = opts[:postgres], do: fun.()
      sqlite?() -> if fun = opts[:sqlite], do: fun.()
      true -> :ok
    end
  end

  # ============================================================================
  # Table Recreation Helpers
  # ============================================================================

  @doc """
  Recreate a table with a new schema definition.

  For SQLite: Performs full table recreation (rename -> create -> copy -> drop).
  For PostgreSQL: Executes the provided ALTER statements.

  ## Options

  - `:table` - Table name (atom, required)
  - `:columns` - List of column definitions as `{name, type, opts}` tuples (required)
  - `:indexes` - List of index specs (optional)
  - `:timestamps` - Timestamp options, `false` to disable, or keyword opts (default: `[type: :utc_datetime]`)
  - `:primary_key` - Primary key option for `create table` (default: `false` for binary_id tables)
  - `:postgres` - List of ALTER SQL strings for PostgreSQL, or `:skip` to do nothing

  ## Column Definition Format

      {name, type, opts}

  Where `opts` can include:
  - `null: false` - NOT NULL constraint
  - `default: value` - Default value
  - `primary_key: true` - Mark as primary key
  - `references: {table, opts}` - Foreign key reference

  ## Index Specification Format

  - `[:col1, :col2]` - Simple index on columns
  - `{[:col1], unique: true}` - Index with options

  ## Example

      recreate_table(
        table: :library_paths,
        primary_key: false,
        columns: [
          {:id, :binary_id, [primary_key: true]},
          {:path, :string, [null: false]},
          {:type, :string, [null: false]},
          {:monitored, :boolean, [default: true]},
          {:quality_profile_id, :binary_id, [references: {:quality_profiles, [type: :binary_id, on_delete: :nilify_all]}]}
        ],
        indexes: [
          [:monitored],
          [:type],
          [:quality_profile_id]
        ],
        postgres: [
          "ALTER TABLE library_paths DROP CONSTRAINT IF EXISTS library_paths_type_check",
          "ALTER TABLE library_paths ADD CONSTRAINT library_paths_type_check CHECK (type IN ('movies', 'series', 'mixed', 'music', 'books', 'adult'))"
        ]
      )
  """
  def recreate_table(opts) do
    table_name = opts[:table] || raise ArgumentError, ":table option is required"

    if postgres?() do
      case opts[:postgres] do
        :skip ->
          :ok

        nil ->
          :ok

        statements when is_list(statements) ->
          Enum.each(statements, &execute/1)
      end
    else
      sqlite_recreate_table(table_name, opts)
    end
  end

  defp sqlite_recreate_table(table_name, opts) do
    columns = opts[:columns] || raise ArgumentError, ":columns option is required for SQLite"
    indexes = opts[:indexes] || []
    primary_key_opt = Keyword.get(opts, :primary_key, false)
    timestamps_opt = Keyword.get(opts, :timestamps, type: :utc_datetime)

    new_table = :"#{table_name}_new"

    # Build list of column names for copying data
    column_names = Enum.map(columns, &elem(&1, 0))

    # Add timestamp columns if enabled
    column_names =
      if timestamps_opt != false do
        column_names ++ [:inserted_at, :updated_at]
      else
        column_names
      end

    columns_str = Enum.map_join(column_names, ", ", &to_string/1)

    # SQLite table recreation strategy: create NEW → copy → drop OLD → rename NEW.
    # We must NOT rename the original table because SQLite auto-updates FK references
    # in other tables to follow the rename, breaking them when the old table is dropped.

    # Step 1: Create new table with updated schema (using a temp name)
    create table(new_table, primary_key: primary_key_opt) do
      for {col_name, col_type, col_opts} <- columns do
        col_opts = col_opts || []

        case col_opts[:references] do
          {ref_table, ref_opts} ->
            add col_name, references(ref_table, ref_opts), Keyword.delete(col_opts, :references)

          nil ->
            add col_name, col_type, col_opts
        end
      end

      if timestamps_opt != false do
        timestamps(timestamps_opt)
      end
    end

    # Step 2: Copy data from original table
    execute "INSERT INTO #{new_table} (#{columns_str}) SELECT #{columns_str} FROM #{table_name}"

    # Step 3: Drop original table
    drop table(table_name)

    # Step 4: Rename new table to the original name
    # FK references in other tables still point to the original name and remain valid
    rename table(new_table), to: table(table_name)

    # Step 5: Recreate indexes
    for index_spec <- indexes do
      case index_spec do
        {cols, index_opts} when is_list(cols) ->
          create index(table_name, cols, index_opts)

        cols when is_list(cols) ->
          create index(table_name, cols)

        col when is_atom(col) ->
          create index(table_name, [col])
      end
    end
  end

  @doc """
  Modify multiple columns' nullability in a single operation.

  For SQLite: Recreates the table with the new column definitions.
  For PostgreSQL: Executes ALTER COLUMN statements.

  ## Options

  - `:table` - Table name (atom, required)
  - `:columns` - Full column definitions as `{name, type, opts}` tuples (required for SQLite)
  - `:changes` - List of `{column_name, nullable}` tuples specifying the changes
  - `:indexes` - List of index specs to recreate (required for SQLite)
  - `:timestamps` - Timestamp options (default: `[type: :utc_datetime]`)
  - `:primary_key` - Primary key option (default: `false`)

  ## Example

      modify_columns_null(
        table: :download_client_configs,
        changes: [
          {:host, true},
          {:port, true}
        ],
        columns: [
          {:id, :binary_id, [primary_key: true]},
          {:name, :string, [null: false]},
          {:host, :string, []},  # Now nullable
          {:port, :integer, []}, # Now nullable
          # ... rest of columns
        ],
        indexes: [
          {[:name], [unique: true]},
          [:enabled],
          [:priority],
          [:type]
        ]
      )
  """
  def modify_columns_null(opts) do
    table_name = opts[:table] || raise ArgumentError, ":table option is required"
    changes = opts[:changes] || raise ArgumentError, ":changes option is required"

    if postgres?() do
      for {column_name, nullable} <- changes do
        if nullable do
          execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} DROP NOT NULL"
        else
          execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET NOT NULL"
        end
      end
    else
      # SQLite requires full table recreation
      sqlite_recreate_table(table_name, opts)
    end
  end

  @doc false
  # Every table that references `table`, directly or transitively, ordered
  # deepest first: a table always appears before the table it references.
  #
  # Deleting in this order never fires a cascade, because a table's own
  # children are already empty by the time it is emptied. Restoring in the
  # reverse order never violates a foreign key, because a row's target is
  # always back in place before the row is.
  #
  # Takes the repo explicitly rather than calling `Ecto.Migration.repo/0` so it
  # can be exercised without a migration wrapped around it.
  @spec sqlite_fk_children(module(), atom() | String.t()) :: [String.t()]
  def sqlite_fk_children(repo, table) do
    {ordered, _visited} =
      collect_fk_children(
        to_string(table),
        direct_fk_children(repo),
        [to_string(table)],
        [],
        MapSet.new()
      )

    ordered
  end

  defp collect_fk_children(table, graph, stack, acc, visited) do
    graph
    |> Map.get(table, [])
    |> Enum.reduce({acc, visited}, fn child, {acc, visited} ->
      cond do
        child in stack ->
          raise Ecto.MigrationError,
            message:
              "foreign key cycle detected while rebuilding #{List.last(stack)}: " <>
                Enum.join(Enum.reverse([child | stack]), " -> ")

        MapSet.member?(visited, child) ->
          {acc, visited}

        true ->
          {acc, visited} =
            collect_fk_children(child, graph, [child | stack], acc, MapSet.put(visited, child))

          {acc ++ [child], visited}
      end
    end)
  end

  # %{parent_table => [child_table]} for the whole database.
  defp direct_fk_children(repo) do
    %{rows: tables} =
      repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
      )

    Enum.reduce(tables, %{}, fn [table], graph ->
      %{rows: foreign_keys} = repo.query!(~s|PRAGMA foreign_key_list("#{table}")|)

      Enum.reduce(foreign_keys, graph, fn [_id, _seq, parent | _rest], graph ->
        if parent == table do
          graph
        else
          Map.update(graph, parent, [table], fn children ->
            if table in children, do: children, else: children ++ [table]
          end)
        end
      end)
    end)
  end

  # Map Ecto types to PostgreSQL types
  defp pg_type(:string), do: "VARCHAR"
  defp pg_type(:text), do: "TEXT"
  defp pg_type(:integer), do: "INTEGER"
  defp pg_type(:bigint), do: "BIGINT"
  defp pg_type(:boolean), do: "BOOLEAN"
  defp pg_type(:binary_id), do: "UUID"
  defp pg_type(:utc_datetime), do: "TIMESTAMP WITH TIME ZONE"
  defp pg_type(type) when is_atom(type), do: String.upcase(to_string(type))
  defp pg_type(type) when is_binary(type), do: type
end
