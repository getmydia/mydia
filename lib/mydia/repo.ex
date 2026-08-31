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

  ## Deferred event broadcasts

  `transaction/1,2` also flushes `Mydia.Events`' pending-broadcast queue once
  the outermost transaction call commits, and discards it if that call rolls
  back or raises. See `Mydia.Events.create_event/1` for why: it writes
  synchronously inside an ambient transaction (so the event row rolls back
  with everything else) but must not broadcast until that transaction is
  known to have actually committed.
  """
  use Ecto.Repo,
    otp_app: :mydia,
    adapter: Application.compile_env(:mydia, :database_adapter, Ecto.Adapters.SQLite3)

  alias Mydia.Events
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
                 insert_or_update: 2,
                 transaction: 1,
                 transaction: 2

  def insert(subject), do: insert(subject, [])

  def insert(subject, opts),
    do: ForeignKeyGuard.run(fn -> super(subject, opts) end, subject, :insert)

  def update(subject), do: update(subject, [])

  def update(subject, opts),
    do: ForeignKeyGuard.run(fn -> super(subject, opts) end, subject, :update)

  def insert_or_update(changeset), do: insert_or_update(changeset, [])

  def insert_or_update(changeset, opts),
    do: ForeignKeyGuard.run(fn -> super(changeset, opts) end, changeset, :insert_or_update)

  def transaction(fun_or_multi), do: transaction(fun_or_multi, [])

  # Only the outermost `transaction/2` call actually begins/commits a
  # database transaction (Ecto tracks nesting depth and lets inner calls run
  # the given function directly on the same connection), so only it decides
  # whether `Mydia.Events`' pending broadcasts fire. Cleared before starting
  # a fresh top-level transaction too, in case an earlier one raised an
  # exception `Repo.rollback/1` wouldn't -- which would otherwise skip the
  # `discard` below and leak stale events into whatever transaction runs next
  # on this process.
  def transaction(fun_or_multi, opts) do
    top_level? = not in_transaction?()

    if top_level?, do: Events.discard_pending_broadcasts()

    result = super(fun_or_multi, opts)

    if top_level? do
      case result do
        {:ok, _} -> Events.flush_pending_broadcasts()
        _ -> Events.discard_pending_broadcasts()
      end
    end

    result
  end
end
