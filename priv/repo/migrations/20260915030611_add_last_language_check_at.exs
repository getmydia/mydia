defmodule Mydia.Repo.Migrations.AddLastLanguageCheckAt do
  use Ecto.Migration

  # Staleness for the audio-language half of the upgrade sweep. Kept apart
  # from last_upgrade_check_at because the two scans advance differently: the
  # language scan stamps every row it reads without a gap, the quality scan
  # only what it searches. Sharing one column would let either scan starve
  # the other.
  def change do
    alter table(:media_items) do
      add :last_language_check_at, :utc_datetime
    end

    alter table(:episodes) do
      add :last_language_check_at, :utc_datetime
    end

    create index(:media_items, [:last_language_check_at])
    create index(:episodes, [:last_language_check_at])
  end
end
