defmodule Mydia.Repo.Migrations.CreateSubtitleTrackSettings do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  # Per-track corrections live in their own table because embedded tracks have
  # no `subtitles` row at all: that table holds sidecar files, and an embedded
  # track is an ffprobe stream index inside the container. `track_ref` is the
  # stringified index for an embedded track and a `subtitles` UUID for a
  # sidecar, which is exactly the representation the GraphQL wire already uses.
  def up do
    create table(:subtitle_track_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :media_file_id,
          references(:media_files, type: :binary_id, on_delete: :delete_all),
          null: false

      add :track_ref, :text, null: false
      add :offset_ms, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subtitle_track_settings, [:media_file_id, :track_ref])
    create index(:subtitle_track_settings, [:media_file_id])

    # `forced` sits beside the existing `hearing_impaired` boolean. Both are
    # properties of the subtitle file itself rather than corrections applied to
    # it, which is why neither belongs in subtitle_track_settings.
    alter table(:subtitles) do
      add :origin, :text, null: false, default: "provider"
      add :forced, :boolean, null: false, default: false
    end

    # Move any non-zero sync_offset into the new table before dropping it. Every
    # existing row is expected to be 0, but this is written rather than assumed.
    execute("""
    INSERT INTO subtitle_track_settings (id, media_file_id, track_ref, offset_ms, inserted_at, updated_at)
    SELECT #{uuid_expr()}, media_file_id, id, sync_offset, #{now_expr()}, #{now_expr()}
    FROM subtitles
    WHERE sync_offset IS NOT NULL AND sync_offset <> 0
    """)

    # sync_offset carries no index, no constraint, and is not a primary key, so
    # it is directly droppable on both adapters. DROP COLUMN has worked in
    # SQLite since 3.35.0 (the bundled SQLite here is well past that), and
    # down/0 below already relies on the same operation working in reverse for
    # origin and forced.
    alter table(:subtitles) do
      remove :sync_offset
    end
  end

  def down do
    alter table(:subtitles) do
      add :sync_offset, :integer, default: 0
    end

    # Partial restore only, and it cannot be otherwise: subtitle_track_settings
    # also holds offsets for embedded tracks, keyed by an ffprobe stream index
    # rather than a subtitles id, and the pre-migration schema has nowhere to
    # put those, since sync_offset only ever existed on subtitles rows. Rows
    # whose track_ref matches a subtitles.id (sidecar corrections) round-trip
    # here; embedded-track offsets have no home to go back to and are simply
    # dropped along with the table below.
    execute("""
    UPDATE subtitles
    SET sync_offset = (
      SELECT offset_ms FROM subtitle_track_settings
      WHERE subtitle_track_settings.track_ref = CAST(subtitles.id AS TEXT)
    )
    WHERE CAST(id AS TEXT) IN (SELECT track_ref FROM subtitle_track_settings)
    """)

    alter table(:subtitles) do
      remove :origin
      remove :forced
    end

    drop table(:subtitle_track_settings)
  end

  defp uuid_expr, do: if(postgres?(), do: "gen_random_uuid()", else: "lower(hex(randomblob(16)))")

  defp now_expr,
    do: if(postgres?(), do: "NOW() AT TIME ZONE 'utc'", else: "datetime('now')")
end
