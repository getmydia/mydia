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

        case write_durably(dir, path, contents <> "\n") do
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

  # `File.write/2` closes the file descriptor but never calls `fsync`, and
  # never touches the directory entry either. A host crash right after it
  # returns `:ok` can leave the archive truncated, corrupt, or entirely
  # missing on disk (both the file's own dirty pages and the directory's
  # dirty pages can still be sitting in the page cache) while the migration
  # goes on to drop the source tables. Since this archive is the only copy of
  # that data once the drop runs, this needs to be durable, not merely
  # "written":
  #
  #   1. Write to a temp file in the same directory (same filesystem, so the
  #      final rename is atomic).
  #   2. `:file.sync/1` the temp file to flush its data to disk.
  #   3. Rename the temp file into place — atomic on the same filesystem.
  #   4. Open and sync the directory itself, so the rename's directory-entry
  #      update is also flushed rather than only living in the page cache.
  #
  # Any failure returns `{:error, reason}` so the caller's existing
  # abort-before-drop path fires exactly as it does today.
  defp write_durably(dir, path, contents) do
    tmp_path = Path.join(dir, ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}")

    with {:ok, io} <- File.open(tmp_path, [:write, :binary]),
         :ok <- IO.binwrite(io, contents),
         :ok <- :file.sync(io),
         :ok <- File.close(io),
         :ok <- File.rename(tmp_path, path),
         :ok <- sync_dir(dir) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  # `File.open/2` (and plain `:file.open/2`) rejects directories with
  # `:eisdir` — the file driver assumes a regular file unless told otherwise.
  # `:directory` (added in OTP 25, present in the OTP 28 this project runs)
  # is the documented escape hatch for exactly this: obtaining a handle to a
  # directory for the sole purpose of `:file.sync/1`, so a rename's
  # directory-entry update is flushed rather than left sitting in the page
  # cache.
  defp sync_dir(dir) do
    case :file.open(String.to_charlist(dir), [:raw, :read, :directory]) do
      {:ok, fd} ->
        try do
          :file.sync(fd)
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
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
  #
  # `byte_size(value) == 16` alone is too broad: SQLite hands back ordinary
  # TEXT columns as plain Elixir binaries too, and plenty of real strings
  # (e.g. "Boards of Canada") are exactly 16 bytes. Without the UTF-8 check
  # those would be silently reformatted into UUID-looking garbage. Requiring
  # invalid UTF-8 restricts this clause to genuine raw binary data (what
  # PostgreSQL's uuid extension returns); ordinary text always falls through
  # to the text path below. A minority of real UUID bytes are coincidentally
  # valid UTF-8 and will fall through to Base64 instead of formatting as a
  # UUID string — an acceptable trade-off since Base64 is lossless and
  # reversible, while corrupting real text is not.
  def encodable(value) when is_binary(value) and byte_size(value) == 16 do
    if String.valid?(value) do
      encode_binary(value)
    else
      case Ecto.UUID.load(value) do
        {:ok, uuid} -> uuid
        :error -> encode_binary(value)
      end
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
