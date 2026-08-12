defmodule Mydia.Repo.Migrations.AddActiveLinkToCardigannDefinitions do
  use Ecto.Migration

  # Both columns are nullable additions, which SQLite and PostgreSQL both
  # support directly via ALTER TABLE ADD COLUMN. No adapter branching needed.
  def change do
    alter table(:cardigann_definitions) do
      add :active_link, :string
      add :link_status, :text
    end
  end
end
