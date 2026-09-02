defmodule Mydia.Repo.Migrations.AddLockVersionToUserPreferences do
  use Ecto.Migration

  def change do
    alter table(:user_preferences) do
      add :lock_version, :integer, null: false, default: 1
    end
  end
end
