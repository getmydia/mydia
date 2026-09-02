defmodule Mydia.Repo.Migrations.AddTrashedReasonToMediaFiles do
  use Ecto.Migration

  # :text rather than :string on purpose. Ecto.Enum stores strings, and a bare
  # :string becomes varchar(255) on PostgreSQL while staying unconstrained TEXT
  # on SQLite. See test/mydia/repo/migrations/no_varchar_columns_test.exs.
  #
  # Nullable with no backfill. Rows trashed before this column existed cannot
  # have their reason recovered: the scanner, which trashed most of them,
  # never recorded an event to reconstruct it from.
  def change do
    alter table(:media_files) do
      add :trashed_reason, :text
    end
  end
end
