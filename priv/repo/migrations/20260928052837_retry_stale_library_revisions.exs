defmodule Mydia.Repo.Migrations.RetryStaleLibraryRevisions do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  Deliver a library-revision write that lost the race to commit.

  PostgreSQL hands out identity values outside transaction commit order, so a
  delayed writer can apply an older revision than the marker already stored for
  the same media item. The original `mydia_library_revision_apply/3` kept the
  marker monotonic by discarding that write, and the deletion flag went with
  it. A consumer already past the winning revision then never saw the
  transition.

  The replacement keeps the signature `(uuid, bigint, boolean)` and the void
  return. Triggers call `mydia_mark_media_item_changed`, and
  `RevisionFeed.mark_live/1` calls `mydia_library_revision_mark_live`; both
  already reach this function, so callers do not change. Each attempt keeps the
  strict greater-than guard and its own `clock_timestamp()`. When the guard
  rejects the attempt, the function takes another identity value and retries.
  Existing marker rows and the sequence are not rewritten.

  SQLite allocates `AUTOINCREMENT` values inside the write lock, in commit
  order, and has no stored function to replace. Both directions are no-ops
  there. The original migration is left in place so a database that already
  applied it upgrades by replacing the function.
  """

  def up do
    if postgres?() do
      execute("""
      CREATE OR REPLACE FUNCTION mydia_library_revision_apply(
        p_media_item_id uuid, p_revision bigint, p_deleted boolean
      ) RETURNS void
      LANGUAGE plpgsql AS $$
      DECLARE
        v_revision bigint := p_revision;
      BEGIN
        -- Identity values are not ordered by commit. A delayed transaction can
        -- hold a revision older than the marker already stored for this item.
        -- The guard keeps that marker monotonic; a rejection used to drop the
        -- transition, tombstone included. Allocate a fresh identity value and
        -- retry so a consumer already past the earlier commit still observes it.
        -- `clock_timestamp()` stays inside the statement: each attempt records
        -- its own time, matching the original function.
        LOOP
          INSERT INTO media_item_revisions (revision, media_item_id, deleted, changed_at)
          VALUES (
            v_revision,
            p_media_item_id,
            p_deleted,
            timezone('UTC', clock_timestamp())
          )
          ON CONFLICT (media_item_id) DO UPDATE
          SET revision = EXCLUDED.revision,
              deleted = EXCLUDED.deleted,
              changed_at = EXCLUDED.changed_at
          WHERE media_item_revisions.revision < EXCLUDED.revision;

          IF FOUND THEN
            RETURN;
          END IF;

          v_revision := nextval(
            pg_get_serial_sequence('media_item_revisions', 'revision')::regclass
          );
        END LOOP;
      END
      $$
      """)
    end
  end

  def down do
    if postgres?() do
      # The single-attempt upsert this migration replaced. A rejected write is
      # discarded again, including its deletion flag.
      execute("""
      CREATE OR REPLACE FUNCTION mydia_library_revision_apply(
        p_media_item_id uuid, p_revision bigint, p_deleted boolean
      ) RETURNS void
      LANGUAGE sql AS $$
      INSERT INTO media_item_revisions (revision, media_item_id, deleted, changed_at)
      VALUES (p_revision, p_media_item_id, p_deleted, timezone('UTC', clock_timestamp()))
      ON CONFLICT (media_item_id) DO UPDATE
      SET revision = EXCLUDED.revision,
          deleted = EXCLUDED.deleted,
          changed_at = EXCLUDED.changed_at
      WHERE media_item_revisions.revision < EXCLUDED.revision
      $$
      """)
    end
  end
end
