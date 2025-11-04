defmodule Mydia.Repo.Migrations.CreateQualityProfiles do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TABLE quality_profiles (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL UNIQUE,
        upgrades_allowed INTEGER DEFAULT 1 CHECK(upgrades_allowed IN (0, 1)),
        upgrade_until_quality TEXT,
        qualities TEXT NOT NULL,
        rules TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "DROP TABLE IF EXISTS quality_profiles"
    )
  end
end
