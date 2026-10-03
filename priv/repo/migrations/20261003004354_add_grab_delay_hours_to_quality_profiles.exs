defmodule Mydia.Repo.Migrations.AddGrabDelayHoursToQualityProfiles do
  use Ecto.Migration

  def change do
    alter table(:quality_profiles) do
      add :grab_delay_hours, :integer, null: false, default: 0
    end
  end
end
