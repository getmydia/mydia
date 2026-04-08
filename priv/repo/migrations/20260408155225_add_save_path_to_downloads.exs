defmodule Mydia.Repo.Migrations.AddSavePathToDownloads do
  use Ecto.Migration

  def change do
    alter table(:downloads) do
      add :save_path, :string
    end
  end
end
