defmodule Mydia.Repo.Migrations.NoRawTableRebuildTest do
  @moduledoc """
  SQLite table rebuilds must go through `Mydia.Repo.Migrations.Helpers`.

  A hand-rolled create/copy/drop/rename in a migration drops the original
  table. Under PRAGMA foreign_keys=ON that fires every referencing table's
  foreign key actions, which silently deletes or nulls their rows. The helper
  wraps rebuilds in `preserving_fk_children/2`; raw ones get no such
  protection, so new ones are rejected here.
  """
  use ExUnit.Case, async: true

  # Each entry records why that migration is allowed to hand-roll a rebuild.
  @allowed %{
    "20251115185757_make_media_files_path_nullable.exs" =>
      "nothing referenced media_files yet; subtitles and media_hashes arrive in 20251116022802",
    "20251125032719_change_event_actor_id_to_string.exs" =>
      "nothing references events, then or now",
    "20251128014213_add_specialized_library_types.exs" =>
      "rebuild is wrapped in preserving_fk_children/2",
    "20251129052609_make_download_client_host_port_nullable.exs" =>
      "nothing references download_client_configs",
    "20260119194743_make_base_url_nullable_in_indexer_configs.exs" =>
      "nothing references indexer_configs"
  }

  test "no new migration hand-rolls a SQLite table rebuild" do
    offenders =
      "priv/repo/migrations/*.exs"
      |> Path.wildcard()
      |> Enum.filter(&hand_rolled_rebuild?/1)
      |> Enum.map(&Path.basename/1)
      |> Enum.reject(&Map.has_key?(@allowed, &1))
      |> Enum.sort()

    assert offenders == [],
           """
           These migrations rebuild a table by dropping and renaming it, without
           going through Mydia.Repo.Migrations.Helpers:

             #{Enum.join(offenders, "\n  ")}

           Dropping a table fires the foreign key actions of every table that
           references it, which deletes or nulls their rows.

           Use recreate_table/1, or wrap the rebuild in preserving_fk_children/2.
           If the column only needs removing, ALTER TABLE ... DROP COLUMN avoids
           the problem entirely.
           """
  end

  test "every allowlist entry still names a real migration" do
    on_disk = "priv/repo/migrations/*.exs" |> Path.wildcard() |> MapSet.new(&Path.basename/1)
    stale = @allowed |> Map.keys() |> Enum.reject(&MapSet.member?(on_disk, &1)) |> Enum.sort()

    assert stale == [], "allowlist names migrations that no longer exist: #{inspect(stale)}"
  end

  defp hand_rolled_rebuild?(path) do
    source = File.read!(path)

    ~r/DROP TABLE\s+"?(\w+)"?|drop table\(:(\w+)\)/i
    |> Regex.scan(source)
    |> Enum.map(fn match -> Enum.find(tl(match), &(&1 != "")) end)
    |> Enum.filter(& &1)
    |> Enum.any?(fn table ->
      Regex.match?(~r/RENAME TO\s+"?#{table}"?/i, source) or
        Regex.match?(~r/to:\s*table\(:#{table}\)/, source)
    end)
  end
end
