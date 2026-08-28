defmodule Mydia.Repo.Migrations.AddExtraClassificationToMediaFiles do
  use Ecto.Migration

  # :text rather than :string on purpose. Ecto.Enum stores strings, and a bare
  # :string becomes varchar(255) on PostgreSQL while staying unconstrained TEXT
  # on SQLite. See test/mydia/repo/migrations/no_varchar_columns_test.exs.
  def change do
    alter table(:media_files) do
      add :extra_kind, :text
      add :extra_source, :text
      add :extra_checked_at, :utc_datetime
    end
  end
end
