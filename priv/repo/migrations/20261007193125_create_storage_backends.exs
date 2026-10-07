defmodule Mydia.Repo.Migrations.CreateStorageBackends do
  use Ecto.Migration

  def change do
    create table(:storage_backends, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :endpoint, :text
      add :region, :text, null: false, default: "us-east-1"
      add :bucket, :text, null: false
      add :access_key_id, :text, null: false
      add :secret_access_key, :text, null: false
      add :path_style, :boolean, null: false, default: true
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:storage_backends, [:name])
  end
end
