defmodule Mydia.Repo.Migrations.AddMonitorNewSeasonsToMediaItems do
  use Ecto.Migration

  # `monitoring_preset` conflated a one-shot bulk action with a forward-looking
  # rule. This column takes over only the forward-looking half: whether a
  # season that does not exist yet should arrive monitored. Everything else is
  # derived from the episode rows.
  #
  # Only a column add and a data update, so SQLite and PostgreSQL take the same
  # path with no table rebuild.
  def up do
    alter table(:media_items) do
      add :monitor_new_seasons, :string, default: "all"
    end

    # Existing rows: only an explicit :none preset meant "do not monitor new
    # content". Every other preset admitted at least some new episodes, so it
    # maps to "all".
    execute("UPDATE media_items SET monitor_new_seasons = 'all'")

    execute(
      "UPDATE media_items SET monitor_new_seasons = 'none' WHERE monitoring_preset = 'none'"
    )
  end

  def down do
    alter table(:media_items) do
      remove :monitor_new_seasons
    end
  end
end
