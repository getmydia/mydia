defmodule Mydia.Repo.Migrations.AddLimitsToTrackerRuleConfigs do
  use Ecto.Migration

  def change do
    # Optional caps per rolling 24 hours (Mydia.Indexers.TrackerLimits); NULL
    # means no cap.
    alter table(:tracker_rule_configs) do
      add :grab_limit, :integer
      add :query_limit, :integer
    end
  end
end
