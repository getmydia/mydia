defmodule Mydia.Repo.Migrations.DropLegacyConfigSettingsCategoryCheck do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  Drops the `CHECK(category IN (...))` that databases created before the DSL
  conversion (f9521c0c9) still carry on `config_settings`.

  The original raw `CREATE TABLE` listed seven categories. Later the constraint
  was declared "moved to the application layer" and
  `20251118193530_add_crash_reporting_to_config_settings_category` became a
  no-op, which is true for databases created afterwards and false for the ones
  that already had the CHECK. On those, every category added since
  (`metadata`, `streaming`, `feedback`, `flaresolverr`, `remote_access`,
  `cardigann`) fails to save with `Ecto.ConstraintError`, which crashed the
  Indexers page when choosing a Cardigann engine.

  `ConfigSetting.changeset/2` validates the category on every install, so the
  rebuilt table carries no CHECK, matching a fresh database.

  SQLite cannot drop a column constraint, so this rebuilds through
  `recreate_table/1`. PostgreSQL never saw the raw form and needs nothing. The
  guard makes this a no-op on every table without the CHECK, including one that
  has already run it.
  """

  def up do
    if sqlite?() and legacy_category_check?() do
      recreate_table(
        table: :config_settings,
        primary_key: false,
        columns: [
          {:id, :binary_id, [primary_key: true, null: false]},
          {:key, :text, [null: false]},
          {:value, :text, []},
          {:category, :text, [null: false]},
          {:description, :text, []},
          {:updated_by_id, :binary_id,
           [references: {:users, [type: :binary_id, on_delete: :nilify_all]}]}
        ],
        indexes: [
          {[:key], unique: true},
          [:category]
        ],
        postgres: :skip
      )
    end
  end

  # Restoring a stale category list would reject rows saved since.
  def down, do: :ok

  defp legacy_category_check? do
    %{rows: rows} =
      repo().query!(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'config_settings'"
      )

    case rows do
      [[sql]] when is_binary(sql) -> Regex.match?(~r/CHECK\s*\(\s*category\s+IN/i, sql)
      _ -> false
    end
  end
end
