defmodule Mydia.Repo.Migrations.CreateCustomFormats do
  use Ecto.Migration

  def change do
    create table(:custom_formats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :description, :string
      # NOT NULL because every consumer assumes a list: the changeset validates
      # non-empty, and both the admin list and the matcher would fail on nil.
      add :patterns, {:array, :string}, default: [], null: false
      add :overrides_builtin, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:custom_formats, [:slug])

    create table(:quality_profile_custom_formats, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :quality_profile_id,
          references(:quality_profiles, type: :binary_id, on_delete: :delete_all),
          null: false

      add :format_slug, :string, null: false
      add :score, :integer, default: 0, null: false
      add :reject, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:quality_profile_custom_formats, [:quality_profile_id, :format_slug])
    create index(:quality_profile_custom_formats, [:format_slug])
  end
end
