defmodule Mydia.Release.TableArchive do
  @moduledoc """
  Dumps database tables to NDJSON so data can be recovered after a destructive
  migration.

  Runs inside migrations, so it uses raw SQL exclusively. Schema modules are not
  available: the whole point is that the code owning these tables is being
  deleted in the same change.

  One JSON object per line, keyed by column name. Empty tables are skipped and
  no file is written for them, so the presence of a file means there was
  something worth keeping.
  """

  require Logger

  @doc """
  Archives each table in `tables` into `dir`, returning row counts per table.

  Returns `{:error, reason}` without writing further files if any table fails.
  Callers inside a migration MUST abort on error rather than proceeding to drop.
  """
  @spec archive_tables(module(), [String.t()], Path.t()) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, term()}
  def archive_tables(repo, tables, dir) do
    with :ok <- File.mkdir_p(dir) do
      Enum.reduce_while(tables, {:ok, %{}}, fn table, {:ok, counts} ->
        case archive_table(repo, table, dir) do
          {:ok, count} -> {:cont, {:ok, Map.put(counts, table, count)}}
          {:error, reason} -> {:halt, {:error, {table, reason}}}
        end
      end)
    end
  end

  defp archive_table(repo, table, dir) do
    %{columns: columns, rows: rows} =
      Ecto.Adapters.SQL.query!(repo, ~s(SELECT * FROM "#{table}"), [])

    case rows do
      [] ->
        Logger.info("[TableArchive] #{table}: empty, nothing archived")
        {:ok, 0}

      rows ->
        path = Path.join(dir, "#{table}.ndjson")
        contents = Enum.map_join(rows, "\n", &encode_row(columns, &1))

        case File.write(path, contents <> "\n") do
          :ok ->
            Logger.info("[TableArchive] #{table}: archived #{length(rows)} rows to #{path}")
            {:ok, length(rows)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    exception -> {:error, exception}
  end

  defp encode_row(columns, values) do
    columns
    |> Enum.zip(Enum.map(values, &encodable/1))
    |> Map.new()
    |> Jason.encode!()
  end

  # SQLite and PostgreSQL disagree on representations for dates, times, and
  # binaries. Anything Jason cannot encode natively becomes a safe textual form
  # so an archive never fails on an unexpected value.
  #
  # Exposed (not `defp`) so the pure encoding rules can be unit tested
  # directly: SQLite's raw driver never hands back `%Date{}` / `%Time{}` /
  # `%NaiveDateTime{}` / `%DateTime{}` structs (those only appear coming out of
  # Postgrex), so the only way to exercise those clauses without a live
  # Postgres connection is to call this function directly. Not part of the
  # module's public contract; `@doc false` keeps it out of generated docs.
  @doc false
  @spec encodable(term()) :: term()
  def encodable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def encodable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def encodable(%Date{} = value), do: Date.to_iso8601(value)
  def encodable(%Time{} = value), do: Time.to_iso8601(value)

  # All 12 tables this archives use `:binary_id` primary keys (and mostly
  # `:binary_id` foreign keys). Raw SQL bypasses Ecto's type-casting layer, so
  # SQLite (`:binary_id` mapped to `:string`) hands back a plain-text UUID
  # while PostgreSQL hands back the raw 16-byte binary. Reformat a 16-byte
  # binary as a canonical UUID string so ids stay human-readable in the
  # archive rather than becoming an opaque Base64 blob. `Ecto.UUID.load/1`
  # only returns `:error` for inputs that are not exactly 16 bytes, so this
  # falls through to the general binary handling below for anything else.
  def encodable(value) when is_binary(value) and byte_size(value) == 16 do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> encode_binary(value)
    end
  end

  def encodable(value) when is_binary(value), do: encode_binary(value)

  def encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  def encodable(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, encodable(v)} end)
  def encodable(value), do: value

  defp encode_binary(value) do
    if String.valid?(value), do: value, else: Base.encode64(value)
  end
end
