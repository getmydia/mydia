defmodule Mydia.Repo.Migrations.CreateMediaItemRevisions do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  The database-owned aggregate revision boundary for the Library API.

  `media_item_revisions` holds one row per media-item UUID: the latest revision
  that item's fully serialized representation changed at. A `revision` is a
  database-generated monotonic integer, so a consumer can page a forward-only
  feed without the second-precision wall-clock races that `media_items.updated_at`
  had. Deletions keep their row as a tombstone (`deleted = true`) and the marker
  deliberately has no foreign key to `media_items`: a foreign key would either
  delete the tombstone or block the parent delete.

  Triggers own the revision allocation. They cover writes that bypass the
  contexts, including `Repo.update_all/2`, `Repo.delete_all/2`, cascades and
  future callers, which an application-level hook cannot. Only columns that can
  change the Library API representation are watched: file-analysis counters,
  download byte progress and similar bookkeeping deliberately do not advance a
  revision.

  Every child trigger resolves its owner through a still-live `media_items` row,
  so a cascade that deletes a parent's children cannot mark the parent live again
  after the parent's own tombstone was written.
  """

  # Every trigger this migration installs. `down/0` drops exactly this set, then
  # the functions those triggers call, then the tables. PostgreSQL keeps trigger
  # functions in the same list: each trigger function is named after its trigger,
  # so the two cannot drift apart.
  @triggers [
    {"media_items", "mydia_library_revision_media_items_insert"},
    {"media_items", "mydia_library_revision_media_items_update"},
    {"media_items", "mydia_library_revision_media_items_delete"},
    {"episodes", "mydia_library_revision_episodes_insert"},
    {"episodes", "mydia_library_revision_episodes_update"},
    {"episodes", "mydia_library_revision_episodes_delete"},
    {"media_files", "mydia_library_revision_media_files_insert"},
    {"media_files", "mydia_library_revision_media_files_update"},
    {"media_files", "mydia_library_revision_media_files_delete"},
    {"media_file_episodes", "mydia_library_revision_media_file_episodes_insert"},
    {"media_file_episodes", "mydia_library_revision_media_file_episodes_delete"},
    {"downloads", "mydia_library_revision_downloads_insert"},
    {"downloads", "mydia_library_revision_downloads_update"},
    {"downloads", "mydia_library_revision_downloads_delete"},
    {"quality_profiles", "mydia_library_revision_quality_profiles_update"},
    {"quality_profiles", "mydia_library_revision_quality_profiles_delete"}
  ]

  # The shared PostgreSQL helpers. The marker upsert and its greatest-revision
  # guard live in `mydia_library_revision_apply/3` alone, so there is one place
  # that decides whether a stale write may replace a committed revision.
  @helper_functions [
    "mydia_mark_media_item_changed",
    "mydia_library_revision_apply",
    "mydia_library_revision_mark_live",
    "mydia_library_revision_mark_episode_owner",
    "mydia_library_revision_mark_download",
    "mydia_library_revision_mark_file",
    "mydia_library_revision_mark_profile_items"
  ]

  # Columns whose change alters the serialized representation. Everything else on
  # these tables (analysis counters, byte progress, observation timestamps) is
  # invisible to a Library API consumer and must not advance a revision.
  @episode_observed_columns ~w(
    media_item_id season_number episode_number title air_date monitored
    provider_episode_id metadata
  )
  @media_file_observed_columns ~w(media_item_id episode_id trashed_at extra_kind)
  @download_observed_columns ~w(media_item_id episode_id completed_at error_message)

  def up do
    create_revision_table()
    create_clock_table()

    # Triggers are installed BEFORE the backfill, and the backfill runs inside
    # the same transaction. Installing a trigger takes a lock that blocks
    # writers until this transaction commits, so ordering the install first
    # closes the window where a concurrent update or delete could commit after
    # the backfill's snapshot but before the trigger existed. Such a write
    # would leave the feed holding a stale marker or a live marker for a
    # deleted row, and no later revision would ever report the change.
    if postgres?() do
      install_postgres_functions()
      install_postgres_triggers()
    else
      install_sqlite_triggers()
    end

    backfill_markers()
    seed_clock()
  end

  def down do
    Enum.each(@triggers, fn {table, name} ->
      if postgres?() do
        execute("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      else
        execute("DROP TRIGGER IF EXISTS #{name}")
      end
    end)

    if postgres?() do
      Enum.each(@triggers, fn {_table, name} ->
        execute("DROP FUNCTION IF EXISTS #{name}")
      end)

      Enum.each(@helper_functions, fn name ->
        execute("DROP FUNCTION IF EXISTS #{name}")
      end)
    end

    drop table(:media_item_revisions)
    drop table(:library_revision_clock)
  end

  # --- tables and backfill -------------------------------------------------

  # The revision column is the adapter's native monotonic 64-bit integer: an
  # identity column on PostgreSQL, an AUTOINCREMENT rowid on SQLite. Both allocate
  # the revision an upsert attempts before the unique conflict on `media_item_id`
  # is resolved, which is what lets a conflict update replace an older revision.
  defp create_revision_table do
    if postgres?() do
      execute("""
      CREATE TABLE media_item_revisions (
        revision BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
        media_item_id UUID NOT NULL UNIQUE,
        deleted BOOLEAN NOT NULL DEFAULT FALSE,
        changed_at TIMESTAMP(6) WITHOUT TIME ZONE NOT NULL DEFAULT timezone('UTC', clock_timestamp())
      )
      """)
    else
      execute("""
      CREATE TABLE media_item_revisions (
        revision INTEGER PRIMARY KEY AUTOINCREMENT,
        media_item_id TEXT NOT NULL UNIQUE,
        deleted INTEGER NOT NULL DEFAULT 0,
        changed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f', 'now'))
      )
      """)
    end
  end

  # A singleton watermark for the UTC-day clock sweep. The check constraint keeps
  # it a singleton at the database level rather than by convention.
  defp create_clock_table do
    execute("""
    CREATE TABLE library_revision_clock (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      last_processed_date DATE NOT NULL
    )
    """)
  end

  # One live marker per existing item. Every write after this point is covered by
  # the triggers below, which are installed before the migration commits, so there
  # is no window in which a write could go unrecorded.
  defp backfill_markers do
    if postgres?() do
      execute("""
      INSERT INTO media_item_revisions (media_item_id, deleted, changed_at)
      SELECT id, FALSE, timezone('UTC', now()) FROM media_items
      """)
    else
      execute("""
      INSERT INTO media_item_revisions (media_item_id, deleted, changed_at)
      SELECT id, 0, strftime('%Y-%m-%d %H:%M:%f', 'now') FROM media_items
      """)
    end
  end

  # Today, because the backfill already represents every prior state change.
  defp seed_clock do
    execute(
      "INSERT INTO library_revision_clock (id, last_processed_date) VALUES (1, '#{Date.utc_today()}')"
    )
  end

  # --- PostgreSQL ----------------------------------------------------------

  defp install_postgres_functions do
    # The one place a revision is written. `p_deleted` lets the parent delete
    # trigger write its tombstone; every child trigger passes false.
    execute("""
    CREATE FUNCTION mydia_mark_media_item_changed(
      p_media_item_id uuid, p_deleted boolean DEFAULT false
    ) RETURNS void
    LANGUAGE plpgsql AS $$
    BEGIN
      IF p_media_item_id IS NULL THEN
        RETURN;
      END IF;

      PERFORM mydia_library_revision_apply(
        p_media_item_id,
        nextval(pg_get_serial_sequence('media_item_revisions', 'revision')::regclass),
        p_deleted
      );
    END
    $$
    """)

    # Applies one already-allocated revision. PostgreSQL identity values are
    # handed out outside commit order, so a delayed transaction can hold a lower
    # revision than one that has already committed. The conflict update only
    # replaces the stored revision when the incoming one is greater, which makes
    # the marker monotonic under either commit order.
    #
    # `clock_timestamp()`, not `now()`. `now()` is the *transaction* start time
    # and is identical for every statement in a transaction, so a child change
    # made after (or alongside) the parent's own write would leave `changed_at`
    # exactly where it was and `MediaItem.updatedAt` would fail to advance. The
    # SQLite triggers use `strftime('%f', 'now')`, which is already per-statement.
    execute("""
    CREATE FUNCTION mydia_library_revision_apply(
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

    # Marks a live owner, but only while the media item still exists. This is
    # what stops a parent's cascading child deletes from resurrecting the
    # tombstone the parent delete trigger just wrote.
    execute("""
    CREATE FUNCTION mydia_library_revision_mark_live(p_media_item_id uuid)
    RETURNS void
    LANGUAGE plpgsql AS $$
    BEGIN
      IF p_media_item_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM media_items WHERE id = p_media_item_id) THEN
        PERFORM mydia_mark_media_item_changed(p_media_item_id, false);
      END IF;
    END
    $$
    """)

    execute("""
    CREATE FUNCTION mydia_library_revision_mark_episode_owner(p_episode_id uuid)
    RETURNS void
    LANGUAGE plpgsql AS $$
    BEGIN
      IF p_episode_id IS NOT NULL THEN
        PERFORM mydia_library_revision_mark_live(
          (SELECT e.media_item_id FROM episodes e WHERE e.id = p_episode_id)
        );
      END IF;
    END
    $$
    """)

    execute("""
    CREATE FUNCTION mydia_library_revision_mark_download(
      p_media_item_id uuid, p_episode_id uuid
    ) RETURNS void
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM mydia_library_revision_mark_live(p_media_item_id);
      PERFORM mydia_library_revision_mark_episode_owner(p_episode_id);
    END
    $$
    """)

    # Every media item that owns (or owned) this file: the file's own parent, its
    # primary episode's media item, and every episode linked through
    # media_file_episodes. Duplicates collapse in the UNION, and every branch
    # joins through a live `media_items` row.
    execute("""
    CREATE FUNCTION mydia_library_revision_mark_file(
      p_media_file_id uuid, p_media_item_id uuid, p_episode_id uuid
    ) RETURNS void
    LANGUAGE plpgsql AS $$
    DECLARE
      v_owner uuid;
    BEGIN
      FOR v_owner IN
        SELECT m.id FROM media_items m WHERE m.id = p_media_item_id
        UNION
        SELECT e.media_item_id
        FROM episodes e JOIN media_items m ON m.id = e.media_item_id
        WHERE e.id = p_episode_id
        UNION
        SELECT e.media_item_id
        FROM media_file_episodes mfe
        JOIN episodes e ON e.id = mfe.episode_id
        JOIN media_items m ON m.id = e.media_item_id
        WHERE mfe.media_file_id = p_media_file_id
      LOOP
        PERFORM mydia_mark_media_item_changed(v_owner, false);
      END LOOP;
    END
    $$
    """)

    execute("""
    CREATE FUNCTION mydia_library_revision_mark_profile_items(p_profile_id uuid)
    RETURNS void
    LANGUAGE plpgsql AS $$
    DECLARE
      v_item uuid;
    BEGIN
      IF p_profile_id IS NULL THEN
        RETURN;
      END IF;

      FOR v_item IN SELECT id FROM media_items WHERE quality_profile_id = p_profile_id LOOP
        PERFORM mydia_mark_media_item_changed(v_item, false);
      END LOOP;
    END
    $$
    """)
  end

  defp install_postgres_triggers do
    postgres_trigger(
      "mydia_library_revision_media_items_insert",
      "AFTER INSERT ON media_items",
      nil,
      "PERFORM mydia_mark_media_item_changed(NEW.id, false);"
    )

    # Every parent update is observable: `MediaItemView` reads the parent row's
    # own columns directly.
    #
    # Deliberately unconditional, with no `UPDATE OF <columns>` list. Per the
    # design spec's "Trigger coverage > media_items" section
    # (docs/superpowers/specs/2026-09-12-library-api-revision-polling-design.md),
    # "insert and every update are observable", and false-positive delivery is
    # safe while a missed change is not. Sweep-only writes such as
    # `seasons_refreshed_at` (`Media.stamp_seasons_refreshed/1`) and
    # `season_order` therefore advance a revision on purpose, and a new column
    # added to `MediaItemView.item_map/2` is covered without a migration change.
    # Narrowing this to a column list would trade that safety for a few avoided
    # deliveries; if that is ever wanted, it needs a spec change first.
    postgres_trigger(
      "mydia_library_revision_media_items_update",
      "AFTER UPDATE ON media_items",
      nil,
      "PERFORM mydia_mark_media_item_changed(NEW.id, false);"
    )

    postgres_trigger(
      "mydia_library_revision_media_items_delete",
      "AFTER DELETE ON media_items",
      nil,
      "PERFORM mydia_mark_media_item_changed(OLD.id, true);"
    )

    postgres_trigger(
      "mydia_library_revision_episodes_insert",
      "AFTER INSERT ON episodes",
      nil,
      "PERFORM mydia_library_revision_mark_live(NEW.media_item_id);"
    )

    # A re-parented episode is observable on both shows: the one that lost it and
    # the one that gained it.
    postgres_trigger(
      "mydia_library_revision_episodes_update",
      "AFTER UPDATE OF #{Enum.join(@episode_observed_columns, ", ")} ON episodes",
      observed_change_clause(@episode_observed_columns),
      """
        PERFORM mydia_library_revision_mark_live(NEW.media_item_id);

        IF NEW.media_item_id IS DISTINCT FROM OLD.media_item_id THEN
          PERFORM mydia_library_revision_mark_live(OLD.media_item_id);
        END IF;
      """
    )

    postgres_trigger(
      "mydia_library_revision_episodes_delete",
      "AFTER DELETE ON episodes",
      nil,
      "PERFORM mydia_library_revision_mark_live(OLD.media_item_id);"
    )

    postgres_trigger(
      "mydia_library_revision_media_files_insert",
      "AFTER INSERT ON media_files",
      nil,
      "PERFORM mydia_library_revision_mark_file(NEW.id, NEW.media_item_id, NEW.episode_id);"
    )

    postgres_trigger(
      "mydia_library_revision_media_files_update",
      "AFTER UPDATE OF #{Enum.join(@media_file_observed_columns, ", ")} ON media_files",
      observed_change_clause(@media_file_observed_columns),
      """
        PERFORM mydia_library_revision_mark_file(NEW.id, NEW.media_item_id, NEW.episode_id);

        IF NEW.media_item_id IS DISTINCT FROM OLD.media_item_id
           OR NEW.episode_id IS DISTINCT FROM OLD.episode_id THEN
          PERFORM mydia_library_revision_mark_file(OLD.id, OLD.media_item_id, OLD.episode_id);
        END IF;
      """
    )

    postgres_trigger(
      "mydia_library_revision_media_files_delete",
      "AFTER DELETE ON media_files",
      nil,
      "PERFORM mydia_library_revision_mark_file(OLD.id, OLD.media_item_id, OLD.episode_id);"
    )

    # `Episode.hasFile` reads the join table, so changing a link changes the
    # episode's representation even when `media_files.episode_id` is untouched.
    postgres_trigger(
      "mydia_library_revision_media_file_episodes_insert",
      "AFTER INSERT ON media_file_episodes",
      nil,
      media_file_episode_body("NEW")
    )

    postgres_trigger(
      "mydia_library_revision_media_file_episodes_delete",
      "AFTER DELETE ON media_file_episodes",
      nil,
      media_file_episode_body("OLD")
    )

    postgres_trigger(
      "mydia_library_revision_downloads_insert",
      "AFTER INSERT ON downloads",
      nil,
      "PERFORM mydia_library_revision_mark_download(NEW.media_item_id, NEW.episode_id);"
    )

    postgres_trigger(
      "mydia_library_revision_downloads_update",
      "AFTER UPDATE OF #{Enum.join(@download_observed_columns, ", ")} ON downloads",
      observed_change_clause(@download_observed_columns),
      """
        PERFORM mydia_library_revision_mark_download(NEW.media_item_id, NEW.episode_id);
        PERFORM mydia_library_revision_mark_download(OLD.media_item_id, OLD.episode_id);
      """
    )

    postgres_trigger(
      "mydia_library_revision_downloads_delete",
      "AFTER DELETE ON downloads",
      nil,
      "PERFORM mydia_library_revision_mark_download(OLD.media_item_id, OLD.episode_id);"
    )

    # A profile rename changes the name every referencing item serializes.
    postgres_trigger(
      "mydia_library_revision_quality_profiles_update",
      "AFTER UPDATE OF name ON quality_profiles",
      "WHEN (OLD.name IS DISTINCT FROM NEW.name)",
      "PERFORM mydia_library_revision_mark_profile_items(NEW.id);"
    )

    # Before, not after: the referencing items must be marked while the profile
    # row (and therefore the association to them) still exists. It returns OLD
    # because a BEFORE row trigger returning NULL would cancel the delete.
    postgres_trigger(
      "mydia_library_revision_quality_profiles_delete",
      "BEFORE DELETE ON quality_profiles",
      nil,
      "PERFORM mydia_library_revision_mark_profile_items(OLD.id);",
      "OLD"
    )
  end

  defp media_file_episode_body(row) do
    """
      PERFORM mydia_library_revision_mark_file(
        #{row}.media_file_id,
        (SELECT mf.media_item_id FROM media_files mf WHERE mf.id = #{row}.media_file_id),
        (SELECT mf.episode_id FROM media_files mf WHERE mf.id = #{row}.media_file_id)
      );

      PERFORM mydia_library_revision_mark_episode_owner(#{row}.episode_id);
    """
  end

  defp observed_change_clause(columns) do
    condition =
      columns
      |> Enum.map(&"OLD.#{&1} IS DISTINCT FROM NEW.#{&1}")
      |> Enum.join(" OR ")

    "WHEN (#{condition})"
  end

  # `return_expr` is the trigger function's `RETURN`. PostgreSQL ignores the
  # return value of an `AFTER` trigger, so those return NULL. A row-level
  # `BEFORE` trigger does not: returning NULL cancels the operation it fired for,
  # so a `BEFORE DELETE` returning NULL deletes neither the row nor anything it
  # cascades to, and Ecto reports `Ecto.StaleEntryError` on a delete that matched
  # no rows.
  defp postgres_trigger(name, event, when_clause, body, return_expr \\ "NULL") do
    execute("""
    CREATE FUNCTION #{name}() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
    #{body}
      RETURN #{return_expr};
    END
    $$
    """)

    execute("""
    CREATE TRIGGER #{name}
    #{event} FOR EACH ROW #{when_clause || ""}EXECUTE FUNCTION #{name}()
    """)
  end

  # --- SQLite --------------------------------------------------------------

  # SQLite has no stored trigger function, so every trigger repeats the marker
  # upsert through the builders below. `excluded` is the row the INSERT attempted,
  # whose AUTOINCREMENT revision the database allocated before resolving the
  # unique conflict on `media_item_id`; the guard keeps the greatest revision.
  defp install_sqlite_triggers do
    sqlite_trigger(
      "mydia_library_revision_media_items_insert",
      "AFTER INSERT ON media_items",
      nil,
      sqlite_marker_values("NEW.id", 0)
    )

    # Deliberately unconditional here too: see the matching comment on the
    # PostgreSQL parent trigger above for the spec section
    # (docs/superpowers/specs/2026-09-12-library-api-revision-polling-design.md)
    # and the reasoning. Sweep-only writes advance a revision on purpose, and a
    # missed consumer-visible change is worse than a redundant re-delivery.
    sqlite_trigger(
      "mydia_library_revision_media_items_update",
      "AFTER UPDATE ON media_items",
      nil,
      sqlite_marker_values("NEW.id", 0)
    )

    sqlite_trigger(
      "mydia_library_revision_media_items_delete",
      "AFTER DELETE ON media_items",
      nil,
      sqlite_marker_values("OLD.id", 1)
    )

    sqlite_trigger(
      "mydia_library_revision_episodes_insert",
      "AFTER INSERT ON episodes",
      nil,
      sqlite_marker_upsert("m.id = NEW.media_item_id")
    )

    sqlite_trigger(
      "mydia_library_revision_episodes_update",
      "AFTER UPDATE OF #{Enum.join(@episode_observed_columns, ", ")} ON episodes",
      sqlite_observed_change_clause(@episode_observed_columns),
      sqlite_marker_upsert("m.id IN (OLD.media_item_id, NEW.media_item_id)")
    )

    sqlite_trigger(
      "mydia_library_revision_episodes_delete",
      "AFTER DELETE ON episodes",
      nil,
      sqlite_marker_upsert("m.id = OLD.media_item_id")
    )

    sqlite_trigger(
      "mydia_library_revision_media_files_insert",
      "AFTER INSERT ON media_files",
      nil,
      sqlite_marker_upsert(
        sqlite_file_owners("NEW.id", "SELECT NEW.media_item_id", "NEW.episode_id")
      )
    )

    sqlite_trigger(
      "mydia_library_revision_media_files_update",
      "AFTER UPDATE OF #{Enum.join(@media_file_observed_columns, ", ")} ON media_files",
      sqlite_observed_change_clause(@media_file_observed_columns),
      sqlite_marker_upsert(
        sqlite_file_owners(
          "NEW.id",
          "SELECT OLD.media_item_id UNION SELECT NEW.media_item_id",
          "OLD.episode_id, NEW.episode_id"
        )
      )
    )

    sqlite_trigger(
      "mydia_library_revision_media_files_delete",
      "AFTER DELETE ON media_files",
      nil,
      sqlite_marker_upsert(
        sqlite_file_owners("OLD.id", "SELECT OLD.media_item_id", "OLD.episode_id")
      )
    )

    # The removed link is already gone when a delete trigger runs, so the linked
    # episode's owner is resolved explicitly rather than through the join table.
    sqlite_trigger(
      "mydia_library_revision_media_file_episodes_insert",
      "AFTER INSERT ON media_file_episodes",
      nil,
      sqlite_marker_upsert(sqlite_file_episode_owners("NEW"))
    )

    sqlite_trigger(
      "mydia_library_revision_media_file_episodes_delete",
      "AFTER DELETE ON media_file_episodes",
      nil,
      sqlite_marker_upsert(sqlite_file_episode_owners("OLD"))
    )

    sqlite_trigger(
      "mydia_library_revision_downloads_insert",
      "AFTER INSERT ON downloads",
      nil,
      sqlite_marker_upsert(
        "m.id = NEW.media_item_id OR #{sqlite_episode_owner("NEW.episode_id")}"
      )
    )

    sqlite_trigger(
      "mydia_library_revision_downloads_update",
      "AFTER UPDATE OF #{Enum.join(@download_observed_columns, ", ")} ON downloads",
      sqlite_observed_change_clause(@download_observed_columns),
      sqlite_marker_upsert(
        "m.id IN (OLD.media_item_id, NEW.media_item_id) OR " <>
          sqlite_episode_owner("OLD.episode_id, NEW.episode_id")
      )
    )

    sqlite_trigger(
      "mydia_library_revision_downloads_delete",
      "AFTER DELETE ON downloads",
      nil,
      sqlite_marker_upsert(
        "m.id = OLD.media_item_id OR #{sqlite_episode_owner("OLD.episode_id")}"
      )
    )

    sqlite_trigger(
      "mydia_library_revision_quality_profiles_update",
      "AFTER UPDATE OF name ON quality_profiles",
      "WHEN (OLD.name IS NOT NEW.name)",
      sqlite_marker_upsert("m.quality_profile_id = NEW.id")
    )

    sqlite_trigger(
      "mydia_library_revision_quality_profiles_delete",
      "BEFORE DELETE ON quality_profiles",
      nil,
      sqlite_marker_upsert("m.quality_profile_id = OLD.id")
    )
  end

  # The marker upsert for every owner-selecting trigger. `FROM media_items` is
  # what requires the owner to still be live, and the condition picks the owners
  # out of that live set.
  defp sqlite_marker_upsert(owner_condition) do
    """
    INSERT INTO media_item_revisions (media_item_id, deleted, changed_at)
    SELECT m.id, 0, strftime('%Y-%m-%d %H:%M:%f', 'now')
    FROM media_items AS m
    WHERE #{owner_condition}
    ON CONFLICT (media_item_id) DO UPDATE SET
      revision = excluded.revision,
      deleted = excluded.deleted,
      changed_at = excluded.changed_at
    WHERE media_item_revisions.revision < excluded.revision;
    """
  end

  defp sqlite_marker_values(id_expression, deleted) do
    """
    INSERT INTO media_item_revisions (media_item_id, deleted, changed_at)
    VALUES (#{id_expression}, #{deleted}, strftime('%Y-%m-%d %H:%M:%f', 'now'))
    ON CONFLICT (media_item_id) DO UPDATE SET
      revision = excluded.revision,
      deleted = excluded.deleted,
      changed_at = excluded.changed_at
    WHERE media_item_revisions.revision < excluded.revision;
    """
  end

  # Media-item ids owning the given file: the file's own parent, its primary
  # episode's media item, and every episode linked through media_file_episodes.
  # The two fragments are the call site's, because insert, update and delete
  # resolve their owners from different rows.
  defp sqlite_file_owners(file_id, direct_owner_select, episode_ids) do
    """
    m.id IN (
        #{direct_owner_select}
        UNION SELECT e.media_item_id FROM episodes e WHERE e.id IN (#{episode_ids})
        UNION SELECT e2.media_item_id
              FROM media_file_episodes mfe JOIN episodes e2 ON e2.id = mfe.episode_id
              WHERE mfe.media_file_id = #{file_id}
      )
    """
  end

  defp sqlite_file_episode_owners(row) do
    """
    m.id IN (
        SELECT mf.media_item_id FROM media_files mf WHERE mf.id = #{row}.media_file_id
        UNION SELECT mp.media_item_id
              FROM media_files mf JOIN episodes mp ON mp.id = mf.episode_id
              WHERE mf.id = #{row}.media_file_id
        UNION SELECT e.media_item_id FROM episodes e WHERE e.id = #{row}.episode_id
        UNION SELECT e2.media_item_id
              FROM media_file_episodes mfe JOIN episodes e2 ON e2.id = mfe.episode_id
              WHERE mfe.media_file_id = #{row}.media_file_id
      )
    """
  end

  # The download triggers own either the download's media item or its episode's,
  # so this resolves one or two episode ids to media-item ids.
  defp sqlite_episode_owner(episode_ids) do
    "m.id IN (SELECT e.media_item_id FROM episodes e WHERE e.id IN (#{episode_ids}))"
  end

  defp sqlite_observed_change_clause(columns) do
    condition =
      columns
      |> Enum.map(&"OLD.#{&1} IS NOT NEW.#{&1}")
      |> Enum.join(" OR ")

    "WHEN (#{condition})"
  end

  defp sqlite_trigger(name, event, when_clause, body) do
    execute("""
    CREATE TRIGGER #{name}
    #{event} FOR EACH ROW #{when_clause || ""}BEGIN
      #{body}
    END
    """)
  end
end
