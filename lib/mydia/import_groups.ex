defmodule Mydia.ImportGroups do
  @moduledoc """
  Query and decision surface for import groups.

  Everything the review page reads goes through here, and every count comes
  from SQL rather than from walking a loaded collection. That is the property
  that makes the page independent of library size: the working set is one page
  of groups, never one row per file.
  """

  import Ecto.Query

  alias Mydia.Library.ImportGroup
  alias Mydia.Library.MatchCandidate
  alias Mydia.Library.MediaFile
  alias Mydia.Library.PathAnchor
  alias Mydia.Repo

  @auto_accept_threshold 0.85
  @default_page_size 50
  @upsert_chunk 500

  # The bind-parameter cap `stamp_members/2` guards against. PostgreSQL caps
  # bound parameters at 65,535 and SQLite at 32,766; an unbounded `id in ^ids`
  # is a crash at scale on either adapter, not just slow.
  @id_bind_chunk 500

  @doc """
  The confidence at or above which a group is considered settled.

  Calibrated against the production library on 2026-08-17, whose candidates
  cluster at 0.65-0.70 and 0.90-1.00 with nothing in between. Every value in
  [0.75, 0.89] produces the same partition there, so this is a robust choice
  rather than a tuned one. `Mydia.Library.FileIngest` reads the same number.
  """
  @spec auto_accept_threshold() :: float()
  def auto_accept_threshold, do: @auto_accept_threshold

  @doc """
  Which review band a group falls into.

  Disagreement beats confidence: if the group's members did not all resolve the
  same provider id, a human should look at it however certain each individual
  file was.
  """
  @spec band(ImportGroup.t()) :: :ready | :needs_attention | :no_match
  def band(%ImportGroup{provider_id: nil}), do: :no_match

  def band(%ImportGroup{} = group) do
    cond do
      disagreement?(group) -> :needs_attention
      is_nil(group.min_confidence) -> :needs_attention
      group.min_confidence >= @auto_accept_threshold -> :ready
      true -> :needs_attention
    end
  end

  defp disagreement?(%ImportGroup{evidence: %{"disagreement" => true}}), do: true
  defp disagreement?(_), do: false

  @doc "Counts pending groups per band for one library path."
  @spec band_counts(binary()) :: %{
          ready: non_neg_integer(),
          needs_attention: non_neg_integer(),
          no_match: non_neg_integer(),
          total: non_neg_integer()
        }
  def band_counts(library_path_id) do
    # Folded in Elixir rather than aggregated in SQL: `band/1` reads the JSON
    # evidence column, and CLAUDE.md forbids SQL aggregates over the kinds of
    # values this would otherwise need to CASE over on two adapters.
    ImportGroup
    |> where([g], g.library_path_id == ^library_path_id and g.status == "pending")
    |> select([g], %{
      provider_id: g.provider_id,
      min_confidence: g.min_confidence,
      evidence: g.evidence
    })
    |> Repo.all()
    |> Enum.reduce(%{ready: 0, needs_attention: 0, no_match: 0, total: 0}, fn row, acc ->
      key = band(struct(ImportGroup, row))

      acc
      |> Map.update!(key, &(&1 + 1))
      |> Map.update!(:total, &(&1 + 1))
    end)
  end

  @doc """
  One keyset page of pending groups, newest-largest first.

  Returns `{groups, cursor}`; `cursor` is nil when the page is the last one.
  Pass the cursor back as `:after`. Ordering is `{file_count desc, id asc}`, so
  the biggest blast radius is decided first and the first screenful of
  decisions covers most of the library's files.
  """
  @spec page(binary(), keyword()) :: {[ImportGroup.t()], term() | nil}
  def page(library_path_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)

    groups =
      library_path_id
      |> base_query()
      |> apply_band(Keyword.get(opts, :band))
      |> apply_search(Keyword.get(opts, :q))
      |> apply_cursor(Keyword.get(opts, :after))
      |> order_by([g], desc: g.file_count, asc: g.id)
      |> limit(^(limit + 1))
      |> Repo.all()

    case Enum.split(groups, limit) do
      {page, []} -> {page, nil}
      {page, _extra} -> {page, cursor_for(List.last(page))}
    end
  end

  @doc """
  Recomputes every group for one library path from its unresolved files.

  Idempotent and resumable. A group that already exists keeps its `status` and
  `decided_at`, so recomputing after a rescan never un-decides a human's answer;
  only the rollup columns are refreshed.

  Processes in keyset chunks of #{@upsert_chunk} files so a 200,000-file library
  never materialises at once.
  """
  @spec upsert_for_library(Mydia.Settings.LibraryPath.t(), keyword()) ::
          {:ok, %{groups: non_neg_integer(), files: non_neg_integer()}}
  def upsert_for_library(library_path, opts \\ []) do
    run_id = Keyword.get(opts, :import_run_id)

    {rollups, file_count} = collect_rollups(library_path)

    group_ids =
      rollups
      |> Enum.map(fn {cluster_key, rollup} ->
        {cluster_key, write_group(library_path, cluster_key, rollup, run_id)}
      end)
      |> Map.new()

    stamp_members(library_path, group_ids)

    {:ok, %{groups: map_size(group_ids), files: file_count}}
  end

  defp base_query(library_path_id) do
    ImportGroup
    |> where([g], g.library_path_id == ^library_path_id and g.status == "pending")
  end

  defp apply_band(query, nil), do: query
  defp apply_band(query, :all), do: query

  defp apply_band(query, :no_match), do: where(query, [g], is_nil(g.provider_id))

  defp apply_band(query, :ready) do
    where(
      query,
      [g],
      not is_nil(g.provider_id) and g.min_confidence >= ^@auto_accept_threshold
    )
  end

  defp apply_band(query, :needs_attention) do
    where(
      query,
      [g],
      not is_nil(g.provider_id) and g.min_confidence < ^@auto_accept_threshold
    )
  end

  defp apply_search(query, q) when is_binary(q) and q != "" do
    like = "%" <> escape_like(q) <> "%"

    where(
      query,
      [g],
      fragment("LOWER(?) LIKE LOWER(?) ESCAPE '\\'", g.anchor_path, ^like)
    )
  end

  defp apply_search(query, _), do: query

  # Backslash must be escaped first, or the escapes added on the next two
  # lines get escaped again. `_` is LIKE's single-character wildcard and shows
  # up constantly in release folder names, so it needs the same treatment as
  # `%`. The `ESCAPE '\'` clause above is what makes this backslash convention
  # take effect: PostgreSQL treats backslash as the implicit LIKE escape, but
  # SQLite has no escape character at all unless one is declared.
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {file_count, id}) do
    where(
      query,
      [g],
      g.file_count < ^file_count or (g.file_count == ^file_count and g.id > ^id)
    )
  end

  defp cursor_for(%ImportGroup{file_count: file_count, id: id}), do: {file_count, id}

  # Streams unresolved files in id-keyset chunks and folds them into one rollup
  # per cluster key. Only the columns the rollup needs are selected: whole
  # MediaFile structs drag the blob columns and are what made the old inbox
  # query unusable.
  defp collect_rollups(library_path) do
    library_path
    |> stream_unresolved()
    |> Enum.reduce({%{}, 0}, fn row, {acc, count} ->
      {fold_row(row, acc, library_path), count + 1}
    end)
  end

  defp unresolved_chunk(library_path_id, nil, limit),
    do: unresolved_base(library_path_id) |> limit(^limit) |> Repo.all()

  defp unresolved_chunk(library_path_id, last_id, limit) do
    unresolved_base(library_path_id)
    |> where([f], f.id > ^last_id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp unresolved_base(library_path_id) do
    MediaFile
    |> where([f], f.library_path_id == ^library_path_id)
    |> where([f], is_nil(f.media_item_id) and is_nil(f.episode_id) and is_nil(f.trashed_at))
    |> join(:left, [f], c in MatchCandidate, on: c.media_file_id == f.id and c.rank == 0)
    |> order_by([f], asc: f.id)
    |> select([f, c], %{
      id: f.id,
      relative_path: f.relative_path,
      provider_id: c.provider_id,
      provider_type: c.provider_type,
      title: c.title,
      year: c.year,
      media_type: c.media_type,
      confidence: c.confidence,
      parsed_info: c.parsed_info
    })
  end

  defp fold_row(row, acc, library_path) do
    anchor =
      PathAnchor.anchor_for(Path.join(library_path.path, row.relative_path), library_path.path)

    Map.update(
      acc,
      anchor.cluster_key,
      initial_rollup(anchor, row),
      &merge_rollup(&1, anchor, row)
    )
  end

  defp initial_rollup(anchor, row) do
    %{
      anchor_path: anchor.anchor_path,
      display_title: display_title(anchor),
      file_count: 1,
      numbered_count: numbered(row),
      provider_ids: MapSet.new(List.wrap(row.provider_id)),
      provider_id: row.provider_id,
      provider_type: row.provider_type,
      suggested_title: row.title,
      suggested_year: row.year,
      media_type: row.media_type,
      min_confidence: row.confidence,
      seasons: MapSet.new(List.wrap(anchor.season_hint || season_of(row)))
    }
  end

  defp merge_rollup(rollup, anchor, row) do
    %{
      rollup
      | file_count: rollup.file_count + 1,
        numbered_count: rollup.numbered_count + numbered(row),
        provider_ids: maybe_put(rollup.provider_ids, row.provider_id),
        provider_id: rollup.provider_id || row.provider_id,
        provider_type: rollup.provider_type || row.provider_type,
        suggested_title: rollup.suggested_title || row.title,
        suggested_year: rollup.suggested_year || row.year,
        media_type: rollup.media_type || row.media_type,
        min_confidence: min_conf(rollup.min_confidence, row.confidence),
        seasons: maybe_put(rollup.seasons, anchor.season_hint || season_of(row))
    }
  end

  defp maybe_put(set, nil), do: set
  defp maybe_put(set, value), do: MapSet.put(set, value)

  defp min_conf(nil, b), do: b
  defp min_conf(a, nil), do: a
  defp min_conf(a, b), do: min(a, b)

  defp numbered(%{parsed_info: %{"episodes" => [_ | _]}}), do: 1
  defp numbered(_), do: 0

  defp season_of(%{parsed_info: %{"season" => season}}) when is_integer(season), do: season
  defp season_of(_), do: nil

  defp display_title(%{anchor_path: ""}), do: "Loose files"
  defp display_title(%{anchor_path: anchor_path}), do: Path.basename(anchor_path)

  defp write_group(library_path, cluster_key, rollup, run_id) do
    disagreement = MapSet.size(rollup.provider_ids) > 1

    attrs = %{
      library_path_id: library_path.id,
      import_run_id: run_id,
      anchor_path: rollup.anchor_path,
      cluster_key: cluster_key,
      display_title: rollup.display_title,
      file_count: rollup.file_count,
      unresolved_count: rollup.file_count,
      numbered_count: rollup.numbered_count,
      media_type: rollup.media_type,
      provider_type: rollup.provider_type,
      provider_id: rollup.provider_id,
      suggested_title: rollup.suggested_title,
      suggested_year: rollup.suggested_year,
      # A disagreeing group carries no min_confidence, which is what keeps the
      # SQL `:ready` predicate in page/2 exact without teaching it to read JSON.
      min_confidence: if(disagreement, do: nil, else: rollup.min_confidence),
      evidence: %{
        "kind" => evidence_kind(rollup, disagreement),
        "candidates" => MapSet.size(rollup.provider_ids),
        "disagreement" => disagreement
      },
      season_span: MapSet.to_list(rollup.seasons)
    }

    existing =
      Repo.get_by(ImportGroup, library_path_id: library_path.id, cluster_key: cluster_key)

    # A decided group keeps its status: recomputing must never un-decide a human.
    attrs = if existing, do: Map.drop(attrs, [:status]), else: attrs

    {:ok, group} =
      (existing || %ImportGroup{})
      |> ImportGroup.changeset(attrs)
      |> Repo.insert_or_update()

    group.id
  end

  defp evidence_kind(%{provider_id: nil}, _), do: "none"
  defp evidence_kind(_, true), do: "fuzzy"
  defp evidence_kind(%{min_confidence: c}, _) when is_float(c) and c >= 0.99, do: "exact_title"
  defp evidence_kind(_, _), do: "fuzzy"

  # Stamps import_group_id in ONE streaming pass over the unresolved set.
  #
  # The obvious shape, "for each group, find its files", is O(groups * files):
  # on a 200,000-file library with 3,000 groups that is 600 million anchor
  # computations and 3,000 full table scans. Instead this walks the files once,
  # buffers ids per group, and flushes a buffer as soon as it reaches the bind
  # cap. Total work is O(files) and no buffer exceeds @id_bind_chunk rows.
  defp stamp_members(library_path, group_ids) do
    library_path
    |> stream_unresolved()
    |> Enum.reduce(%{}, fn row, buffers ->
      anchor =
        PathAnchor.anchor_for(
          Path.join(library_path.path, row.relative_path),
          library_path.path
        )

      case Map.fetch(group_ids, anchor.cluster_key) do
        :error ->
          buffers

        {:ok, group_id} ->
          buffer = [row.id | Map.get(buffers, group_id, [])]

          if length(buffer) >= @id_bind_chunk do
            flush(group_id, buffer)
            Map.delete(buffers, group_id)
          else
            Map.put(buffers, group_id, buffer)
          end
      end
    end)
    |> Enum.each(fn {group_id, buffer} -> flush(group_id, buffer) end)
  end

  defp flush(_group_id, []), do: :ok

  defp flush(group_id, ids) do
    MediaFile
    |> where([f], f.id in ^ids)
    |> Repo.update_all(set: [import_group_id: group_id])
  end

  # The same keyset walk collect_rollups/1 uses, exposed as a Stream so both
  # passes share one definition of "unresolved, in id order, in chunks".
  defp stream_unresolved(library_path) do
    Stream.resource(
      fn -> nil end,
      fn
        :done ->
          {:halt, :done}

        last_id ->
          rows = unresolved_chunk(library_path.id, last_id, @upsert_chunk)

          cond do
            rows == [] -> {:halt, :done}
            length(rows) < @upsert_chunk -> {rows, :done}
            true -> {rows, List.last(rows).id}
          end
      end,
      fn _ -> :ok end
    )
  end
end
