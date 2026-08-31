defmodule Mydia.Repo.Migrations.SplitImportCandidatesFromMediaFiles do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  alias Mydia.Library.PathAnchor

  @batch_size 500

  def up do
    create_import_candidates()
    flush()
    backfill_active_orphans()
    delete_all_parentless_media_files()
    drop_old_import_state()
    enforce_media_file_parent_invariant()
  end

  def down do
    raise "split_import_candidates_from_media_files cannot restore discarded orphan analysis or candidate ranks"
  end

  defp create_import_candidates do
    create table(:import_candidates, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :library_path_id,
          references(:library_paths, type: :binary_id, on_delete: :delete_all),
          null: false

      add :relative_path, :text, null: false
      add :anchor_key, :text, null: false
      add :size, :bigint
      add :mtime, :utc_datetime
      add :parsed_info, :text
      add :provider_type, :text
      add :provider_id, :text
      add :title, :text
      add :year, :integer
      add :media_type, :text
      add :confidence, :float
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :next_retry_at, :utc_datetime
      add :dismissed_at, :utc_datetime
      add :discovered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:import_candidates, [:library_path_id, :relative_path])
    create index(:import_candidates, [:library_path_id, :anchor_key])
    create index(:import_candidates, [:library_path_id, :dismissed_at])
  end

  defp backfill_active_orphans(last_id \\ nil) do
    {where, params} =
      case last_id do
        nil -> {"", []}
        id -> {" AND mf.id > $1", [id]}
      end

    %{rows: rows} =
      repo().query!(
        """
        SELECT mf.id, mf.library_path_id, mf.relative_path, mf.size, mf.inserted_at,
               candidate.provider_type, candidate.provider_id, candidate.title,
               candidate.year, candidate.media_type, candidate.confidence,
               candidate.parsed_info, candidate.attempts, candidate.last_error,
               candidate.next_retry_at, lp.path
        FROM media_files AS mf
        JOIN library_paths AS lp ON lp.id = mf.library_path_id
        LEFT JOIN media_file_match_candidates AS candidate
          ON candidate.media_file_id = mf.id AND candidate.rank = 0
        WHERE mf.media_item_id IS NULL
          AND mf.episode_id IS NULL
          AND mf.trashed_at IS NULL#{where}
        ORDER BY mf.id
        LIMIT #{@batch_size}
        """,
        params
      )

    Enum.each(rows, &insert_candidate/1)

    case List.last(rows) do
      nil -> :ok
      [id | _] when length(rows) == @batch_size -> backfill_active_orphans(id)
      _ -> :ok
    end
  end

  defp insert_candidate([
         _media_file_id,
         library_path_id,
         relative_path,
         size,
         inserted_at,
         provider_type,
         provider_id,
         title,
         year,
         media_type,
         confidence,
         parsed_info,
         attempts,
         last_error,
         next_retry_at,
         library_root
       ]) do
    anchor_key =
      Path.join(library_root, relative_path)
      |> PathAnchor.anchor_for(library_root)
      |> Map.fetch!(:cluster_key)

    repo().query!(
      """
      INSERT INTO import_candidates
        (id, library_path_id, relative_path, anchor_key, size, parsed_info,
         provider_type, provider_id, title, year, media_type, confidence,
         attempts, last_error, next_retry_at, discovered_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
              COALESCE($13, 0), $14, $15, $16, $16, $16)
      """,
      [
        Ecto.UUID.bingenerate(),
        library_path_id,
        relative_path,
        anchor_key,
        size,
        parsed_info,
        provider_type,
        provider_id,
        title,
        year,
        media_type,
        confidence,
        attempts,
        last_error,
        next_retry_at,
        inserted_at
      ]
    )
  end

  defp delete_all_parentless_media_files do
    execute """
    DELETE FROM media_files
    WHERE media_item_id IS NULL AND episode_id IS NULL
    """
  end

  defp drop_old_import_state do
    drop table(:media_file_match_candidates)
  end

  defp enforce_media_file_parent_invariant do
    recreate_table(
      table: :media_files,
      primary_key: false,
      columns: media_file_columns(),
      indexes: media_file_indexes(),
      checks: [{:media_files_has_parent, "media_item_id IS NOT NULL OR episode_id IS NOT NULL"}],
      postgres: [
        "ALTER TABLE media_files DROP CONSTRAINT IF EXISTS media_files_episode_id_fkey",
        """
        ALTER TABLE media_files
        ADD CONSTRAINT media_files_episode_id_fkey
        FOREIGN KEY (episode_id) REFERENCES episodes(id) ON DELETE NO ACTION
        """,
        """
        ALTER TABLE media_files
        ADD CONSTRAINT media_files_has_parent
        CHECK (media_item_id IS NOT NULL OR episode_id IS NOT NULL)
        """,
        "ALTER TABLE media_files DROP COLUMN import_group_id",
        "DROP TABLE import_groups"
      ]
    )

    unless postgres?() do
      drop table(:import_groups)
    end
  end

  defp media_file_columns do
    [
      {:id, :binary_id, [primary_key: true]},
      {:media_item_id, :binary_id,
       [references: {:media_items, [type: :binary_id, on_delete: :delete_all]}]},
      {:episode_id, :binary_id,
       [references: {:episodes, [type: :binary_id, on_delete: :nothing]}]},
      {:path, :text, []},
      {:size, :bigint, []},
      {:quality_profile_id, :binary_id, [references: {:quality_profiles, [type: :binary_id]}]},
      {:resolution, :text, []},
      {:codec, :text, []},
      {:hdr_format, :text, []},
      {:dolby_vision_profile, :integer, []},
      {:dolby_vision_bl_compat_id, :integer, []},
      {:hdr_backfilled_at, :utc_datetime, []},
      {:audio_codec, :text, []},
      {:bitrate, :integer, []},
      {:verified_at, :utc_datetime, []},
      {:analyzed_at, :utc_datetime, []},
      {:analysis_attempts, :integer, [null: false, default: 0]},
      {:last_analysis_error, :text, []},
      {:metadata, :text, []},
      {:cover_blob, :text, []},
      {:sprite_blob, :text, []},
      {:vtt_blob, :text, []},
      {:preview_blob, :text, []},
      {:phash, :text, []},
      {:generated_at, :utc_datetime, []},
      {:trashed_at, :utc_datetime, []},
      {:extra_kind, :text, []},
      {:extra_source, :text, []},
      {:extra_checked_at, :utc_datetime, []},
      {:segment_analysis_state, :text, [null: false, default: "pending"]},
      {:segments_analyzed_at, :utc_datetime, []},
      {:segment_analysis_attempts, :integer, [null: false, default: 0]},
      {:last_segment_analysis_error, :text, []},
      {:fingerprint_blob, :text, []},
      {:relative_path, :text, []},
      {:library_path_id, :binary_id,
       [references: {:library_paths, [type: :binary_id, on_delete: :delete_all]}]},
      {:supersedes_media_file_id, :binary_id,
       [references: {:media_files, [type: :binary_id, on_delete: :nilify_all]}]}
    ]
  end

  defp media_file_indexes do
    [
      [:media_item_id],
      [:episode_id],
      [:library_path_id],
      [:phash],
      [:trashed_at],
      {[:analysis_attempts, :inserted_at, :id],
       [where: "analyzed_at IS NULL", name: :media_files_unanalyzed_idx]},
      [:supersedes_media_file_id],
      [:segment_analysis_state],
      [:library_path_id, :relative_path]
    ]
  end
end
