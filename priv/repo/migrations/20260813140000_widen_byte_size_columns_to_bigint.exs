defmodule Mydia.Repo.Migrations.WidenByteSizeColumnsToBigint do
  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  Widen the two byte-size columns still declared `:integer` to `:bigint`.

  On PostgreSQL `:integer` is int4, which caps at 2,147,483,647. Both columns
  receive file sizes in bytes, so every write for a media file over ~2.1 GB
  failed with `DBConnection.EncodeError`. One instance sat in a permanent
  crash loop on this and produced roughly 99% of all crash reports the relay
  had ever received. See issue #278.

  On SQLite this is a no-op: the INTEGER storage class is already 64-bit, which
  is why the bug was invisible on the default adapter. The Ecto DSL cannot
  express this portably either, because `ecto_sqlite3` raises
  `ArgumentError, "ALTER COLUMN not supported by SQLite3"` on `modify`.

  `down` narrows back to `integer` and will fail if any row exceeds int4. That
  is deliberate: a rollback must not silently truncate byte counts.

  PostgreSQL rewrites each table for an int4 to int8 change and holds an ACCESS
  EXCLUSIVE lock for the duration. Both tables are small on a self-hosted
  install, so this is a brief boot-time pause.
  """

  @columns [
    {:transcode_jobs, :file_size},
    {:downloads, :last_known_bytes}
  ]

  def up do
    if postgres?() do
      for {table, column} <- @columns do
        execute("ALTER TABLE #{table} ALTER COLUMN #{column} TYPE bigint")
      end
    end
  end

  def down do
    if postgres?() do
      for {table, column} <- @columns do
        execute("ALTER TABLE #{table} ALTER COLUMN #{column} TYPE integer")
      end
    end
  end
end
