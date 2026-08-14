defmodule Mydia.Repo.Migrations.NoVarcharColumnsTest do
  @moduledoc """
  Migration columns must be `:text`, never `:string`.

  A bare `:string` compiles to `varchar(255)` on PostgreSQL but to unconstrained
  `TEXT` affinity on SQLite. Since SQLite is the default adapter for development
  and test, a write longer than 255 characters passes locally and fails only on
  PostgreSQL with `ERROR 22001 (string_data_right_truncation)`.

  That asymmetry shipped the same bug twice: issue #286 against the library
  scanner, then again through the columns that
  `20260616120000_widen_metadata_text_columns.exs` left behind when it hand-listed
  the six that happened to be crashing.

  `{:array, :string}` is included, since it compiles to `varchar(255)[]` and is
  the shape that survived the first draft of this very guard.

  Two checks, because neither alone is sufficient:

    * The source check runs on every adapter, so a contributor on the default
      SQLite setup gets the failure locally instead of discovering it in the
      PostgreSQL CI job. It only reads migration text, so a column introduced by
      raw `execute` SQL slips past it.
    * The schema check cannot be fooled by how the column was written, but it only
      carries weight where `varchar` is distinguishable from `text`, and on a
      freshly migrated database.

  Length limits the application actually intends belong in changesets via
  `validate_length/3`, where they are visible and adapter-independent.
  """
  use Mydia.DataCase, async: true

  # Migrations that predate the sweep. Their columns were converted in the
  # database rather than by rewriting migration history.
  #
  # This is an explicit list rather than a timestamp cutoff on purpose. Ecto
  # selects pending migrations with `version not in applied_versions`, so a branch
  # cut before the sweep but merged after it runs *after* the sweep on an
  # already-migrated database while running *before* it on a fresh CI one. A
  # cutoff would grandfather exactly that file and let the bug reach production
  # with CI green. A list catches it: the file simply is not on here.
  @grandfathered ~w(
    20251103225445_create_quality_profiles.exs
    20251103225446_create_users.exs
    20251103225447_create_config_tables.exs
    20251104023000_create_media_items.exs
    20251104023001_create_episodes.exs
    20251104023003_create_media_files.exs
    20251104023004_create_downloads.exs
    20251104023006_create_api_keys.exs
    20251105033610_refactor_downloads_remove_state_fields.exs
    20251106191246_create_events.exs
    20251108213827_create_media_requests.exs
    20251114212620_add_relative_path_columns_to_media_files.exs
    20251116022802_create_subtitle_tables.exs
    20251116051018_create_subtitle_providers.exs
    20251116051145_create_cardigann_definitions.exs
    20251116152505_add_health_check_fields_to_cardigann_definitions.exs
    20251120222936_create_import_sessions.exs
    20251124004619_add_enhanced_fields_to_quality_profiles.exs
    20251125032719_change_event_actor_id_to_string.exs
    20251128234700_create_music_tables.exs
    20251128234701_create_books_tables.exs
    20251206040615_add_generated_media_fields_to_media_files.exs
    20251206224051_create_import_lists_tables.exs
    20251207000000_add_cover_blob_to_albums.exs
    20251208025951_create_media_server_configs.exs
    20251208030219_create_playlists_table.exs
    20251209183656_add_category_to_media_items.exs
    20251210013336_create_adult_tables.exs
    20251210154247_add_monitoring_preset_to_media_items.exs
    20251225060000_create_remote_access_tables.exs
    20251225132113_create_pairing_claims.exs
    20251226020220_add_api_key_fields.exs
    20251226051714_remove_relay_url_from_remote_access_config.exs
    20251226052500_add_cert_fingerprint_to_remote_access_config.exs
    20251226204340_create_transcode_jobs.exs
    20251228233655_create_collections.exs
    20260110133111_add_type_and_user_to_transcode_jobs.exs
    20260119193326_add_env_name_to_indexer_configs.exs
    20260119223125_create_search_backoffs.exs
    20260222000000_create_user_integrations.exs
    20260326000000_add_match_status_to_downloads.exs
    20260514131906_create_release_blacklist.exs
    20260604120000_add_tv_metadata_source_to_library_paths.exs
    20260604120100_add_metadata_source_to_media_items.exs
    20260608020000_create_plugin_configs.exs
    20260608120100_add_import_failure_fields_to_downloads.exs
    20260609000001_create_plugin_logs.exs
    20260609000002_create_plugin_kv.exs
    20260609000003_create_plugin_user_connections.exs
    20260730170000_add_quality_upgrade_fields.exs
    20260731130000_create_media_segments.exs
    20260731130100_add_segment_analysis_to_media_files.exs
    20260809202500_create_custom_formats.exs
    20260811100000_add_plex_connection_resilience.exs
    20260811110000_create_sync_runs.exs
    20260811130001_create_watch_sync_tables.exs
    20260811180000_create_media_server_user_links.exs
    20260812000000_add_active_link_to_cardigann_definitions.exs
    20260812180000_replace_subtitle_providers_with_configs.exs
    20260813120000_add_monitor_new_seasons_to_media_items.exs
    20260813130000_drop_monitoring_preset_from_media_items.exs
  )

  # Every form that produces a varchar column on PostgreSQL, with or without
  # parens, since `mix format` preserves both. `remove` counts because in a
  # `change/0` migration the rollback re-adds the column with that type.
  @declarations [
    ~r/^\s*(?:add|add_if_not_exists|modify|remove)\(?\s*:(\w+),\s*:string\b/m,
    ~r/^\s*(?:add|add_if_not_exists|modify|remove)\(?\s*:(\w+),\s*:varchar\b/m,
    ~r/^\s*(?:add|add_if_not_exists|modify|remove)\(?\s*:(\w+),\s*\{:array,\s*:string\}/m,
    ~r/^\s*(?:add|add_if_not_exists|modify)\(?\s*:(\w+),\s*references\([^)]*type:\s*:string/m,
    ~r/modify_column_type\([^,]+,\s*:?(\w+),\s*:string\b/
  ]

  describe "migration source" do
    test "no migration outside the grandfathered set declares a varchar column" do
      offenders =
        migration_files()
        |> Enum.reject(&(Path.basename(&1) in @grandfathered))
        |> Enum.flat_map(&varchar_declarations/1)
        |> Enum.sort()

      assert offenders == [],
             """
             These migrations declare varchar columns:

               #{Enum.join(offenders, "\n  ")}

             `:string` becomes varchar(255) on PostgreSQL but unconstrained TEXT on
             SQLite, so an over-long write passes in development and fails in
             production with ERROR 22001 (string_data_right_truncation).
             `{:array, :string}` has the same problem as varchar(255)[].

             Use `:text` (or `{:array, :text}`) instead. The Ecto schema still
             declares `field :name, :string` either way; only the migration type
             changes. To bound a value, add `validate_length/3` to the changeset.
             """
    end

    test "every grandfathered entry still names a real migration" do
      on_disk = MapSet.new(migration_files(), &Path.basename/1)
      stale = Enum.reject(@grandfathered, &MapSet.member?(on_disk, &1))

      assert stale == [],
             "grandfathered list names migrations that no longer exist: #{inspect(stale)}"
    end

    test "the migration glob actually matches files" do
      assert migration_files() != [], "no migrations found; the wildcard or CWD is wrong"
    end
  end

  # On SQLite `:string` and `:text` are both stored as unconstrained TEXT affinity,
  # so there is no length limit to observe and nothing to assert.
  if Mydia.Repo.__adapter__() == Ecto.Adapters.Postgres do
    describe "migrated schema" do
      # Kept in lockstep with the same query in the sweep migration. Oban and
      # ErrorTracker own their own schemas and ship their own migrations, so
      # neither is swept nor asserted over: a dep bump that adds a varchar column
      # must not fail a guard with no mydia source to fix.
      @query """
      SELECT c.table_name, c.column_name, c.data_type, c.character_maximum_length
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema = c.table_schema
       AND t.table_name = c.table_name
      WHERE c.table_schema = 'public'
        AND (c.data_type = 'character varying'
             OR (c.data_type = 'ARRAY' AND c.udt_name = '_varchar'))
        AND t.table_type = 'BASE TABLE'
        AND c.table_name <> 'schema_migrations'
        AND c.table_name NOT LIKE 'oban\\_%'
        AND c.table_name NOT LIKE 'error\\_tracker\\_%'
      ORDER BY c.table_name, c.column_name
      """

      test "no table declares a varchar column" do
        %{rows: rows} = Repo.query!(@query, [])

        assert rows == [],
               """
               These columns are varchar rather than TEXT:

                 #{Enum.map_join(rows, "\n  ", &describe_column/1)}

               Writes longer than the limit fail on PostgreSQL with ERROR 22001
               (string_data_right_truncation) while passing on SQLite.

               Use `:text` in the migration that adds the column.
               """
      end
    end

    defp describe_column([table, column, "ARRAY", _]), do: "#{table}.#{column} varchar[]"
    defp describe_column([table, column, _, nil]), do: "#{table}.#{column} varchar"
    defp describe_column([table, column, _, len]), do: "#{table}.#{column} varchar(#{len})"
  end

  defp migration_files, do: Path.wildcard("priv/repo/migrations/*.exs")

  defp varchar_declarations(path) do
    source = File.read!(path)

    @declarations
    |> Enum.flat_map(&Regex.scan(&1, source, capture: :all_but_first))
    |> Enum.map(fn [column] -> "#{Path.basename(path)}: #{column}" end)
    |> Enum.uniq()
  end
end
