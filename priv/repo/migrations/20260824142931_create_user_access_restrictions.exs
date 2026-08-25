defmodule Mydia.Repo.Migrations.CreateUserAccessRestrictions do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  Per-account limits on which media categories and content ratings are visible.

  A separate table rather than columns on `users`. The users schema already
  carries `role_changeset/2` as a workaround for OIDC rows failing full
  validation, and adding security-relevant fields there compounds it. Absence
  of a row means unrestricted, which is the safe default for every existing
  account and cannot be produced by a typo.

  `allowed_categories` is `{:array, :string}` in the schema, which needs a real
  `text[]` on PostgreSQL and plain `:text` on SQLite. Migration
  20260223100000_fix_array_columns_for_postgres.exs exists because four other
  columns were created without that branch.
  """

  def change do
    create table(:user_access_restrictions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :allowed_categories, if(postgres?(), do: {:array, :text}, else: :text)
      add :max_content_age, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_access_restrictions, [:user_id])
  end
end
