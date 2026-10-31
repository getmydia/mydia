defmodule Mydia.Repo.Migrations.CreateTrackerRuleConfigsAndSightings do
  use Ecto.Migration

  def change do
    # Per-tracker term overrides edited from the admin Indexers page. They
    # shadow a YAML or env `tracker_rules` entry for the same tracker.
    # `tracker_key` is the trimmed, lowercased name, so uniqueness and lookups
    # are case-insensitive on both adapters without a functional index.
    create table(:tracker_rule_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tracker, :text, null: false
      add :tracker_key, :text, null: false
      add :seed_ratio, :float
      # Minutes.
      add :seed_time, :integer
      add :private, :boolean
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tracker_rule_configs, [:tracker_key])

    # One row per tracker seen in search results: the terms it last reported
    # and when. Backs the admin list of trackers and the stale-override flag.
    create table(:tracker_sightings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tracker, :text, null: false
      add :tracker_key, :text, null: false
      add :private, :boolean
      add :minimum_ratio, :float
      # Seconds.
      add :minimum_seed_time, :integer
      add :last_seen_at, :utc_datetime, null: false
    end

    create unique_index(:tracker_sightings, [:tracker_key])
  end
end
