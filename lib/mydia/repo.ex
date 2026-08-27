defmodule Mydia.Repo do
  @moduledoc """
  Ecto repository for database operations.

  The database adapter is configurable via `:database_adapter` in config:
  - `Ecto.Adapters.SQLite3` (default) - SQLite database
  - `Ecto.Adapters.Postgres` - PostgreSQL database

  Set DATABASE_TYPE=postgres environment variable to use PostgreSQL.

  ## Foreign key errors

  `insert/1,2`, `update/1,2` and `insert_or_update/1,2` are wrapped by
  `Mydia.Repo.ForeignKeyGuard`, which turns SQLite's nameless foreign key
  violations into `{:error, changeset}` rather than a raised
  `Ecto.ConstraintError`. See that module for why SQLite needs it and why the
  wrapper is a no-op on PostgreSQL. `Ecto.Multi` steps are covered, since Multi
  dispatches through these functions.

  `insert_all/3` is **not** covered and cannot be: it takes no changeset, so
  there is nothing to attach an error to, and a foreign key violation there
  still raises on SQLite. A caller passing client-supplied ids to
  `insert_all/3` has to check them itself. `Mydia.Collections.add_items/2` is
  the worked example.
  """
  use Ecto.Repo,
    otp_app: :mydia,
    adapter: Application.compile_env(:mydia, :database_adapter, Ecto.Adapters.SQLite3)

  alias Mydia.Repo.ForeignKeyGuard

  # Ecto blesses only default_options/1, prepare_query/3 and
  # prepare_transaction/2 as overridable, but `use Ecto.Repo` defines these in
  # this module, so defoverridable and super apply normally. Both arities are
  # declared and defined explicitly rather than relying on a default-argument
  # head, so there is no ambiguity about which definition a local call reaches.
  defoverridable insert: 1,
                 insert: 2,
                 update: 1,
                 update: 2,
                 insert_or_update: 1,
                 insert_or_update: 2

  def insert(subject), do: insert(subject, [])

  def insert(subject, opts),
    do: ForeignKeyGuard.run(fn -> super(subject, opts) end, subject, :insert)

  def update(subject), do: update(subject, [])

  def update(subject, opts),
    do: ForeignKeyGuard.run(fn -> super(subject, opts) end, subject, :update)

  def insert_or_update(changeset), do: insert_or_update(changeset, [])

  def insert_or_update(changeset, opts),
    do: ForeignKeyGuard.run(fn -> super(changeset, opts) end, changeset, :insert_or_update)
end
