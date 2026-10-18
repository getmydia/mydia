defmodule Mydia.Repo.Migrations.AddFeedbackToPluginShelfDismissals do
  use Ecto.Migration

  def change do
    alter table(:plugin_shelf_dismissals) do
      add :rating, :text, null: false, default: "down"
      add :via, :text
      add :title, :text
      add :year, :integer
    end
  end
end
