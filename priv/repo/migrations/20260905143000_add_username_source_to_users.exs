defmodule Mydia.Repo.Migrations.AddUsernameSourceToUsers do
  use Ecto.Migration

  @moduledoc """
  Records which tier produced a derived username.

  Without it, "upgrade the name only when the IdP offers a better one" is not
  decidable: a stored `robin` could equally be what the operator typed or what
  a backfill took from an email address, and only one of those may be
  overwritten. NULL means the name was chosen locally.

  `:text` rather than `:string`, which would be varchar(255) on PostgreSQL and
  unconstrained TEXT on SQLite.
  """

  def change do
    alter table(:users) do
      add :username_source, :text
    end
  end
end
