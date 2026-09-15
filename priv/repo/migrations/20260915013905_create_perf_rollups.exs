defmodule Mydia.Repo.Migrations.CreatePerfRollups do
  @moduledoc """
  Hourly performance rollups written by `Mydia.Perf.Flusher`.

  One row per hour, boot, metric and tag set. `boot_id` keeps a restart from
  overwriting the previous boot's rows for the same hour. `sum_us` is `bigint`
  because an hour of one long job is about 3.6e9 microseconds, past a
  PostgreSQL `integer`. The unique index leads with `hour`, which also serves
  the prune and the report's range read.
  """
  use Ecto.Migration

  def change do
    create table(:perf_rollups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :hour, :utc_datetime, null: false
      add :boot_id, :text, null: false
      add :metric, :text, null: false
      add :tags, :text, null: false
      add :count, :integer, null: false
      add :sum_us, :bigint, null: false
      add :buckets, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:perf_rollups, [:hour, :boot_id, :metric, :tags])
  end
end
