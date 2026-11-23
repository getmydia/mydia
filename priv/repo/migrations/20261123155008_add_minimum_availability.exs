defmodule Mydia.Repo.Migrations.AddMinimumAvailability do
  @moduledoc """
  Adds the per-movie `media_items.minimum_availability` override, and keeps
  existing installs searching the way they did before the setting existed.

  The global `media.minimum_availability` defaults to `released`, which stops
  automatic search from looking for a movie before it could have been
  released. An install that already holds movies gets an `announced` row in
  `config_settings` instead, so upgrading changes nothing until its operator
  chooses a level. A fresh install has no movies when this runs, gets no row,
  and uses the default.
  """

  use Ecto.Migration

  @key "media.minimum_availability"

  def up do
    alter table(:media_items) do
      add :minimum_availability, :text
    end

    keep_existing_behaviour()
  end

  def down do
    query_repo().query!("DELETE FROM config_settings WHERE key = $1", [@key])

    alter table(:media_items) do
      remove :minimum_availability
    end
  end

  @doc false
  def keep_existing_behaviour do
    if movies?(), do: insert_announced_setting()
    :ok
  end

  defp movies? do
    %{rows: rows} =
      query_repo().query!("SELECT 1 FROM media_items WHERE type = 'movie' LIMIT 1")

    rows != []
  end

  # Postgres stores binary_id as uuid and wants the 16-byte form; SQLite stores
  # it as text.
  defp insert_announced_setting do
    id =
      if query_repo().__adapter__() == Ecto.Adapters.Postgres,
        do: Ecto.UUID.bingenerate(),
        else: Ecto.UUID.generate()

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    query_repo().query!(
      """
      INSERT INTO config_settings (id, key, value, category, inserted_at, updated_at)
      VALUES ($1, $2, 'announced', 'media', $3, $3)
      ON CONFLICT (key) DO NOTHING
      """,
      [id, @key, now]
    )
  end

  # `repo/0` from Ecto.Migration only works inside a migration runner. Tests
  # call `keep_existing_behaviour/0` directly, so fall back to Mydia.Repo
  # outside that context.
  defp query_repo do
    case Process.get(:ecto_migration) do
      %{runner: _} -> repo()
      _ -> Mydia.Repo
    end
  end
end
