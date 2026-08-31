defmodule Mydia.Repo.Migrations.BackfillImportGroups do
  @moduledoc """
  Populates the short-lived `import_groups` projection for unresolved files.

  This migration is deliberately self-contained. Released migrations may run
  years later against a populated install, after the runtime context that
  originally built this projection has been removed or renamed. The next
  import-pipeline migration replaces these groups with path-keyed candidates,
  but an install still has to cross this version safely to reach it.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    %{rows: libraries} =
      repo().query!("""
      SELECT id, path, type
      FROM library_paths
      WHERE type IN ('series', 'movies')
      ORDER BY id
      """)

    Enum.each(libraries, fn [library_path_id, library_root, library_type] ->
      rows = unresolved_rows(library_path_id)

      groups = Enum.group_by(rows, &cluster_key(&1, library_type))

      Enum.each(groups, fn {key, members} ->
        group_id = upsert_group(library_path_id, key, members)
        Enum.each(members, &stamp_member(&1, group_id))
      end)

      IO.puts(
        "[backfill_import_groups] #{library_root}: " <>
          "#{map_size(groups)} groups over #{length(rows)} unresolved files"
      )
    end)
  end

  def down, do: :ok

  defp unresolved_rows(library_path_id) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT mf.id, mf.relative_path,
               candidate.provider_type, candidate.provider_id, candidate.title,
               candidate.year, candidate.media_type, candidate.confidence
        FROM media_files AS mf
        LEFT JOIN media_file_match_candidates AS candidate
          ON candidate.media_file_id = mf.id AND candidate.rank = 0
        WHERE mf.library_path_id = $1
          AND mf.media_item_id IS NULL
          AND mf.episode_id IS NULL
          AND mf.trashed_at IS NULL
        ORDER BY mf.id
        """,
        [library_path_id]
      )

    rows
  end

  defp cluster_key(
         [id, _path, _provider_type, _provider_id, _title, _year, _media_type, _],
         "movies"
       ),
       do: "file-" <> encoded_id(id)

  defp cluster_key(
         [id, _path, _provider_type, _provider_id, _title, _year, "movie", _],
         _library_type
       ),
       do: "file-" <> encoded_id(id)

  defp cluster_key([_id, relative_path | _], _library_type) do
    relative_path
    |> first_path_segment()
    |> normalize_anchor()
  end

  defp first_path_segment(relative_path) do
    case Path.split(relative_path || "") do
      [_file] -> "__root__"
      [segment | _] -> segment
      [] -> "__root__"
    end
  end

  defp normalize_anchor("__root__"), do: "__root__"

  defp normalize_anchor(segment) do
    normalized =
      segment
      |> String.replace(~r/\[[^\]]*\]/, " ")
      |> String.replace(~r/\((?:18|19|20)\d{2}\)/, " ")
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    if normalized == "", do: "__root__", else: normalized
  end

  defp upsert_group(library_path_id, cluster_key, members) do
    [first | _] = members
    [_id, relative_path, provider_type, provider_id, title, year, media_type, _confidence] = first
    provider_ids = members |> Enum.map(&Enum.at(&1, 3)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    confidences = members |> Enum.map(&List.last/1) |> Enum.reject(&is_nil/1)
    disagreement = length(provider_ids) > 1
    min_confidence = if disagreement or confidences == [], do: nil, else: Enum.min(confidences)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    id = Ecto.UUID.bingenerate()
    anchor_path = if cluster_key == "__root__", do: "", else: Path.dirname(relative_path || "")
    display_title = title || display_title(cluster_key, relative_path)

    repo().query!(
      """
      INSERT INTO import_groups
        (id, library_path_id, anchor_path, cluster_key, display_title,
         file_count, unresolved_count, numbered_count, media_type,
         provider_type, provider_id, suggested_title, suggested_year,
         min_confidence, evidence, season_span, status, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, $4, $5, $6, $6, 0, $7, $8, $9, $10, $11,
         $12, $13, $14, 'pending', $15, $15)
      ON CONFLICT (library_path_id, cluster_key) DO UPDATE SET
        anchor_path = excluded.anchor_path,
        display_title = excluded.display_title,
        file_count = excluded.file_count,
        unresolved_count = excluded.unresolved_count,
        media_type = excluded.media_type,
        provider_type = excluded.provider_type,
        provider_id = excluded.provider_id,
        suggested_title = excluded.suggested_title,
        suggested_year = excluded.suggested_year,
        min_confidence = excluded.min_confidence,
        evidence = excluded.evidence,
        updated_at = excluded.updated_at
      """,
      [
        id,
        library_path_id,
        anchor_path,
        cluster_key,
        display_title,
        length(members),
        media_type,
        provider_type,
        provider_id,
        title,
        year,
        min_confidence,
        ~s({"disagreement":#{disagreement},"candidates":#{length(provider_ids)}}),
        "[]",
        now
      ]
    )

    %{rows: [[group_id]]} =
      repo().query!(
        "SELECT id FROM import_groups WHERE library_path_id = $1 AND cluster_key = $2",
        [library_path_id, cluster_key]
      )

    group_id
  end

  defp stamp_member([media_file_id | _], group_id) do
    repo().query!("UPDATE media_files SET import_group_id = $1 WHERE id = $2", [
      group_id,
      media_file_id
    ])
  end

  defp display_title("__root__", relative_path),
    do: Path.rootname(Path.basename(relative_path || "Loose files"))

  defp display_title(cluster_key, _relative_path), do: cluster_key

  defp encoded_id(id) when is_binary(id), do: Base.url_encode64(id, padding: false)
end
