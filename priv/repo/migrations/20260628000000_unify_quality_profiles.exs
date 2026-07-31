defmodule Mydia.Repo.Migrations.UnifyQualityProfiles do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  alias Mydia.Repo.Migrations.QualityProfileBackfill

  def up do
    backfill_preferred_resolutions()
    drop_dead_columns()
  end

  def down do
    raise Ecto.MigrationError,
      message: "unify_quality_profiles is a one-way clean-break migration and cannot be reverted"
  end

  # --- Backfill ---

  defp backfill_preferred_resolutions do
    # A replayed migration (schema_migrations reset, or a database restored from
    # a point after `qualities` was already dropped) has nothing left to
    # backfill from, and selecting a missing column would abort the migration.
    if column_exists?("quality_profiles", "qualities") do
      %{rows: rows} =
        repo().query!("SELECT id, qualities, quality_standards FROM quality_profiles")

      Enum.each(rows, fn [id, qualities_raw, standards_raw] ->
        qualities = decode_list(qualities_raw)
        standards = decode_map(standards_raw)
        new_standards = QualityProfileBackfill.backfilled_standards(qualities, standards)

        if new_standards != standards do
          encoded = Jason.encode!(new_standards)
          {sql, params} = update_sql(encoded, id)
          repo().query!(sql, params)
        end
      end)
    end
  end

  defp column_exists?(table, column) do
    if postgres?() do
      %{rows: rows} =
        repo().query!(
          "SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
          [table, column]
        )

      rows != []
    else
      sqlite_column?(table, column)
    end
  end

  defp update_sql(encoded, id) do
    if postgres?() do
      {"UPDATE quality_profiles SET quality_standards = $1 WHERE id = $2", [encoded, id]}
    else
      {"UPDATE quality_profiles SET quality_standards = ? WHERE id = ?", [encoded, id]}
    end
  end

  defp decode_list(nil), do: []
  defp decode_list(""), do: []

  defp decode_list(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_list(list) when is_list(list), do: list
  defp decode_list(_), do: []

  defp decode_map(nil), do: %{}
  defp decode_map(""), do: %{}

  defp decode_map(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_map(map) when is_map(map), do: map
  defp decode_map(_), do: %{}

  # --- Drop columns (adapter-aware) ---

  @dead_columns ~w(qualities metadata_preferences customizations)

  defp drop_dead_columns do
    if postgres?() do
      for column <- @dead_columns do
        execute("ALTER TABLE quality_profiles DROP COLUMN IF EXISTS #{column}")
      end
    else
      # Rebuilding the table here would drop it, and under PRAGMA foreign_keys=ON
      # that fires the foreign key actions of media_files, media_items,
      # library_paths, and import_lists: an abort from the first and silently
      # erased assignments from the other three. Dropping the columns in place
      # touches no foreign key at all.
      #
      # SQLite has had ALTER TABLE ... DROP COLUMN since 3.35 and exqlite bundles
      # 3.53. None of these columns is indexed or constrained, which is what
      # SQLite requires for a direct drop. There is no IF EXISTS form, so the
      # presence check makes a replay safe.
      for column <- @dead_columns, sqlite_column?("quality_profiles", column) do
        execute(~s|ALTER TABLE quality_profiles DROP COLUMN "#{column}"|)
      end
    end
  end

  defp sqlite_column?(table, column) do
    %{rows: rows} = repo().query!(~s|PRAGMA table_info("#{table}")|)
    Enum.any?(rows, fn [_cid, name | _] -> name == column end)
  end
end
