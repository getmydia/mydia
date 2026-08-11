defmodule Mydia.Repo.Migrations.BackfillDefaultLibraryFlags do
  use Ecto.Migration
  import Ecto.Query

  @moduledoc """
  Flags the oldest monitored library of each kind as that kind's default.

  Oldest-wins reproduces most installs' behaviour before the default flags
  existed: destination was previously the alphabetically-first compatible
  library, and for a single-library install that is the first one created.
  It is a guess, but a visible one, correctable in the settings UI.

  Written with Ecto queries rather than raw SQL so boolean rendering stays
  adapter-agnostic (SQLite stores 1/0, PostgreSQL true/false).
  """

  @kinds [
    {:default_for_movies, ["movies", "mixed"]},
    {:default_for_series, ["series", "mixed"]}
  ]

  def up, do: backfill()

  # Irreversible by design: down/0 would have to guess which flags were
  # operator-set after the fact. Clearing all of them would silently change
  # behaviour on rollback.
  def down, do: :ok

  @doc false
  def backfill do
    Enum.each(@kinds, fn {field, types} -> backfill_kind(field, types) end)
    :ok
  end

  defp backfill_kind(field, types) do
    unless already_flagged?(field) do
      case oldest_candidate(field, types) do
        nil ->
          :ok

        id ->
          query_repo().update_all(
            from(l in "library_paths", where: l.id == type(^id, :binary_id)),
            set: [{field, boolean_true()}]
          )
      end
    end
  end

  defp already_flagged?(field) do
    query_repo().exists?(from(l in "library_paths", where: field(l, ^field) == true))
  end

  defp oldest_candidate(_field, types) do
    from(l in "library_paths",
      where: l.type in ^types,
      where: l.monitored == true,
      where: l.disabled == false or is_nil(l.disabled),
      order_by: [asc: l.inserted_at, asc: l.id],
      limit: 1,
      select: type(l.id, :binary_id)
    )
    |> query_repo().one()
  end

  # Schemaless update_all has no column type, so Elixir `true` is dumped as the
  # string "true" on SQLite. Match what Ecto.Adapters.SQLite3 stores for booleans.
  defp boolean_true do
    case query_repo().__adapter__() do
      Ecto.Adapters.SQLite3 -> 1
      _ -> true
    end
  end

  # `repo/0` from Ecto.Migration only works inside a migration runner. Tests
  # call `backfill/0` directly, so fall back to Mydia.Repo outside that context.
  defp query_repo do
    case Process.get(:ecto_migration) do
      %{runner: _} -> repo()
      _ -> Mydia.Repo
    end
  end
end
