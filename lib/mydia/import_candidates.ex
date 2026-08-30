defmodule Mydia.ImportCandidates do
  @moduledoc """
  Persistence and review operations for durable import candidates.

  There is no persisted rollup table behind a "group" here. A group is
  `Mydia.Library.ImportCandidateGroup`, computed on every read by
  `group_query/2` aggregating `import_candidates` rows for one library path.
  That is what makes review decisions durable while grouping stays free: a
  candidate carries its own `dismissed_at`, and a group simply stops existing
  the moment its last candidate is dismissed, promoted, or deleted -- there is
  no separate row to keep in sync.
  """

  import Ecto.Query

  require Logger

  alias Mydia.Library.{
    BatchMatcher,
    CandidatePromotion,
    FileIngest,
    ImportCandidateGroup,
    ImportRun,
    MediaFile,
    PathAnchor,
    SelectionScope
  }

  alias Mydia.Media
  alias Mydia.Media.Episode
  alias Mydia.Metadata
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath

  alias Mydia.Library.ImportCandidate

  @doc """
  The confidence at or above which a group is considered settled.

  See `Mydia.Library.FileIngest.default_threshold/0`, which reads the same
  number for the analogous unattended-import decision. Both are pinned at
  0.85 by design; they are not derived from one another so that this module
  does not carry a compile-time dependency on `FileIngest`.
  """
  @auto_accept_threshold 0.85
  @default_page_size 50

  # Cap on how many `%ImportCandidate{}` rows `members/2` returns for display.
  # A group can hold tens of thousands of files and the review page must
  # never render them all.
  @member_display_limit 200

  # Page size used internally when a group's *entire* membership must be
  # walked (accepting it, or turning it into a local show). Bounded so a
  # group the size of a whole season tree never becomes one unbounded
  # allocation, while still being processed as a single logical group.
  @member_page_size 500

  @type cursor :: {non_neg_integer(), String.t()}

  @spec upsert(map() | keyword()) :: {:ok, ImportCandidate.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    attrs = Map.new(attrs)
    library_path_id = Map.fetch!(attrs, :library_path_id)
    relative_path = Map.fetch!(attrs, :relative_path)

    case Repo.get_by(ImportCandidate,
           library_path_id: library_path_id,
           relative_path: relative_path
         ) do
      nil -> insert_or_update(%ImportCandidate{}, attrs, library_path_id, relative_path)
      existing -> insert_or_update(existing, attrs, library_path_id, relative_path)
    end
  end

  @spec get_by_path(binary(), String.t()) :: ImportCandidate.t() | nil
  def get_by_path(library_path_id, relative_path) do
    Repo.get_by(ImportCandidate, library_path_id: library_path_id, relative_path: relative_path)
  end

  @spec delete_missing(binary(), [String.t()]) :: {non_neg_integer(), nil | [term()]}
  def delete_missing(library_path_id, relative_paths) do
    ImportCandidate
    |> where([candidate], candidate.library_path_id == ^library_path_id)
    |> where([candidate], candidate.relative_path not in ^relative_paths)
    |> Repo.delete_all()
  end

  @spec demote_episode_files(Episode.t()) :: {:ok, :ok} | {:error, term()}
  def demote_episode_files(%Episode{} = episode) do
    Repo.transaction(fn ->
      episode = Repo.preload(episode, [:media_item, media_files: :library_path])

      Enum.each(episode.media_files, fn file ->
        library_path = file.library_path

        anchor =
          PathAnchor.anchor_for(
            Path.join(library_path.path, file.relative_path),
            library_path.path
          )

        {provider_type, provider_id} = provider_identity(episode.media_item)

        case upsert(%{
               library_path_id: file.library_path_id,
               relative_path: file.relative_path,
               anchor_key: anchor.cluster_key,
               size: file.size,
               discovered_at: file.inserted_at,
               provider_type: provider_type,
               provider_id: provider_id,
               media_type: "tv_show",
               parsed_info: %{
                 "type" => "tv_show",
                 "season" => episode.season_number,
                 "episodes" => [episode.episode_number]
               }
             }) do
          {:ok, _candidate} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end

        Repo.delete!(file)
      end)

      :ok
    end)
  end

  # --- Grouped read model -------------------------------------------------

  @doc "The confidence at or above which a group is considered settled."
  @spec auto_accept_threshold() :: float()
  def auto_accept_threshold, do: @auto_accept_threshold

  @doc """
  Which review band a group falls into.

  Mirrors the `HAVING` predicates `group_query/2` applies in SQL: the two
  must agree; `import_candidates_test.exs` proves it for every band this
  clause set can produce.
  """
  @spec band(ImportCandidateGroup.t()) :: :ready | :needs_attention | :no_match
  def band(%ImportCandidateGroup{provider_id: nil}), do: :no_match
  def band(%ImportCandidateGroup{provider_type: "local"}), do: :needs_attention

  def band(%ImportCandidateGroup{} = group) do
    cond do
      is_nil(group.min_confidence) -> :needs_attention
      group.min_confidence >= @auto_accept_threshold -> :ready
      true -> :needs_attention
    end
  end

  @doc """
  One portable grouped query over `import_candidates` for one library path.

  Groups by `anchor_key`, aggregating `count(id)`, `min(confidence)`, and
  `count(distinct provider_id)` alongside representative (`max/1`)
  provider/title/type values. Every row this returns is a plain map; convert
  it with the private `to_group/2` used by `page/2`, or read `:anchor_key`
  straight off it, e.g. as a subquery of matching anchor keys (see
  `Mydia.Library.SelectionScope.to_query/1`, which delegates here).

  `:status` (default `"pending"`) selects undismissed candidates; anything
  else selects dismissed ones. `:band` and `:q` apply the same predicates
  `page/2` exposes.
  """
  @spec group_query(binary(), keyword()) :: Ecto.Query.t()
  def group_query(library_path_id, opts \\ []) do
    status = Keyword.get(opts, :status, "pending")

    ImportCandidate
    |> where([c], c.library_path_id == ^library_path_id)
    |> filter_dismissed(status)
    # `library_path_id` is constant across every row here (the WHERE clause
    # above already pins it), but PostgreSQL still requires a plain
    # (non-aggregate) selected column to appear in GROUP BY -- SQLite is
    # lenient about this and would let it through unmodified, so leaving it
    # out here would work in dev/test on SQLite and break on PostgreSQL.
    |> group_by([c], [c.anchor_key, c.library_path_id])
    |> select([c], %{
      anchor_key: c.anchor_key,
      library_path_id: c.library_path_id,
      file_count: count(c.id),
      min_confidence: min(c.confidence),
      provider_count: count(c.provider_id, :distinct),
      provider_id: max(c.provider_id),
      provider_type: max(c.provider_type),
      suggested_title: max(c.title),
      suggested_year: max(c.year),
      media_type: max(c.media_type)
    })
    |> apply_band(Keyword.get(opts, :band))
    |> apply_search(Keyword.get(opts, :q))
  end

  defp filter_dismissed(query, "pending"), do: where(query, [c], is_nil(c.dismissed_at))
  defp filter_dismissed(query, _status), do: where(query, [c], not is_nil(c.dismissed_at))

  defp apply_band(query, nil), do: query
  defp apply_band(query, :all), do: query

  defp apply_band(query, :no_match) do
    having(query, [c], is_nil(max(c.provider_id)))
  end

  defp apply_band(query, :ready) do
    threshold = @auto_accept_threshold

    having(
      query,
      [c],
      count(c.provider_id, :distinct) == 1 and min(c.confidence) >= ^threshold and
        (is_nil(max(c.provider_type)) or max(c.provider_type) != "local")
    )
  end

  defp apply_band(query, :needs_attention) do
    threshold = @auto_accept_threshold

    having(
      query,
      [c],
      not is_nil(max(c.provider_id)) and
        (count(c.provider_id, :distinct) != 1 or min(c.confidence) < ^threshold)
    )
  end

  # `ilike/2` raises on SQLite, so this is a LOWER/LIKE fragment with an
  # explicit ESCAPE clause: PostgreSQL treats backslash as the implicit LIKE
  # escape, but SQLite has none unless one is declared, so without this an
  # escaped `%` stays a live wildcard on SQLite while PostgreSQL treats it
  # literally -- the two adapters would return different rows for the same
  # search. Matches against `anchor_key` (there is no persisted `anchor_path`
  # column any more) via a plain WHERE: every row in an anchor shares the
  # same `anchor_key`, so filtering rows before the GROUP BY is equivalent to
  # filtering groups, without disturbing any other group's aggregate.
  defp apply_search(query, q) when is_binary(q) and q != "" do
    like = "%" <> escape_like(q) <> "%"

    where(
      query,
      [c],
      fragment("LOWER(?) LIKE LOWER(?) ESCAPE '\\'", c.anchor_key, ^like)
    )
  end

  defp apply_search(query, _), do: query

  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  One keyset page of groups, largest-first.

  Returns `{groups, cursor}`; `cursor` is `nil` when the page is the last
  one. Pass it back as `:after`. Ordering is `{file_count desc, anchor_key
  asc}` -- the tie-break is what makes the page stable when two groups share
  a file count, rather than repeating or skipping a row depending on however
  the database happened to order equal keys.

  Never loads the underlying candidate rows: every group on the page is one
  aggregate row, so this stays independent of library size -- the review page
  never has to walk one row per file just to render a page of groups.
  """
  @spec page(binary(), keyword()) :: {[ImportCandidateGroup.t()], cursor() | nil}
  def page(library_path_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)
    status = Keyword.get(opts, :status, "pending")

    groups =
      library_path_id
      |> group_query(status: status, band: Keyword.get(opts, :band), q: Keyword.get(opts, :q))
      |> apply_cursor(Keyword.get(opts, :after))
      |> order_by([c], desc: count(c.id), asc: c.anchor_key)
      |> limit(^(limit + 1))
      |> Repo.all()
      |> Enum.map(&to_group(&1, status))

    case Enum.split(groups, limit) do
      {page, []} -> {page, nil}
      {page, _extra} -> {page, cursor_for(List.last(page))}
    end
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {file_count, anchor_key}) do
    having(
      query,
      [c],
      count(c.id) < ^file_count or (count(c.id) == ^file_count and c.anchor_key > ^anchor_key)
    )
  end

  defp cursor_for(%ImportCandidateGroup{file_count: file_count, anchor_key: anchor_key}),
    do: {file_count, anchor_key}

  defp to_group(row, status) do
    min_confidence = if row.provider_count > 1, do: nil, else: row.min_confidence

    %ImportCandidateGroup{
      id: row.anchor_key,
      anchor_key: row.anchor_key,
      library_path_id: row.library_path_id,
      display_title: display_title(row),
      file_count: row.file_count,
      provider_type: row.provider_type,
      provider_id: row.provider_id,
      suggested_title: row.suggested_title,
      suggested_year: row.suggested_year,
      media_type: row.media_type,
      min_confidence: min_confidence,
      provider_count: row.provider_count,
      dismissed?: status != "pending"
    }
  end

  defp display_title(%{anchor_key: "__root__"}), do: "Loose files"
  defp display_title(%{suggested_title: title}) when is_binary(title) and title != "", do: title
  defp display_title(%{anchor_key: key}), do: humanize(key)

  defp humanize(key) do
    key
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  Counts pending groups per band for one library path.
  """
  @spec band_counts(binary()) :: %{
          ready: non_neg_integer(),
          needs_attention: non_neg_integer(),
          no_match: non_neg_integer(),
          total: non_neg_integer()
        }
  def band_counts(library_path_id) do
    counts =
      Map.new([:ready, :needs_attention, :no_match], fn band ->
        {band, count_groups(library_path_id, band: band)}
      end)

    Map.put(counts, :total, counts.ready + counts.needs_attention + counts.no_match)
  end

  @doc """
  Total pending groups across every importable library path, for the
  navigation badge.

  Counts distinct `(library_path_id, anchor_key)` pairs directly rather than
  reusing `group_query/2`'s full aggregate select (which would compute
  columns this caller never reads), and deliberately does not count candidate
  files. Library paths whose type `Mydia.Library.ImportRun.importable_type?/1`
  rejects are excluded, matching the guard the review page itself uses.
  """
  @spec count_pending() :: non_neg_integer()
  def count_pending do
    ImportCandidate
    |> where([c], is_nil(c.dismissed_at))
    |> join(:inner, [c], lp in LibraryPath, on: lp.id == c.library_path_id)
    |> where([c, lp], lp.type in ^ImportRun.importable_types())
    |> group_by([c], [c.library_path_id, c.anchor_key])
    |> select([c], c.anchor_key)
    |> subquery()
    |> Repo.aggregate(:count)
  end

  @doc "How many groups of one status exist for a library path."
  @spec count_by_status(binary(), String.t()) :: non_neg_integer()
  def count_by_status(library_path_id, status) do
    count_groups(library_path_id, status: status)
  end

  defp count_groups(library_path_id, opts) do
    library_path_id
    |> group_query(opts)
    |> subquery()
    |> Repo.aggregate(:count)
  end

  # --- Group membership ----------------------------------------------------

  @doc """
  One group's member candidates, for lazy expansion in the UI.

  Capped at #{@member_display_limit}: a group can hold tens of thousands of
  files and the review page must never render them all.
  """
  @spec members(binary(), String.t()) :: [ImportCandidate.t()]
  def members(library_path_id, anchor_key) do
    ImportCandidate
    |> for_anchor(library_path_id, anchor_key)
    |> order_by([c], asc: c.relative_path)
    |> limit(^@member_display_limit)
    |> Repo.all()
  end

  @doc "How many undismissed candidates a group still has."
  @spec member_count(binary(), String.t()) :: non_neg_integer()
  def member_count(library_path_id, anchor_key) do
    ImportCandidate
    |> for_anchor(library_path_id, anchor_key)
    |> Repo.aggregate(:count)
  end

  defp for_anchor(query, library_path_id, anchor_key) do
    where(
      query,
      [c],
      c.library_path_id == ^library_path_id and c.anchor_key == ^anchor_key and
        is_nil(c.dismissed_at)
    )
  end

  # Walks a whole group's undismissed candidates in keyset pages of
  # #{@member_page_size}, so a group the size of a full season tree is never
  # one unbounded allocation, while still handing callers (`accept/2`,
  # `create_local_show/2`) the complete membership they need to act on the
  # group as a single unit.
  defp load_all_members(library_path_id, anchor_key),
    do: load_all_members(library_path_id, anchor_key, nil, [])

  defp load_all_members(library_path_id, anchor_key, after_path, acc) do
    page =
      ImportCandidate
      |> for_anchor(library_path_id, anchor_key)
      |> maybe_after_path(after_path)
      |> order_by([c], asc: c.relative_path)
      |> limit(^@member_page_size)
      |> Repo.all()

    acc = acc ++ page

    if length(page) < @member_page_size do
      acc
    else
      load_all_members(library_path_id, anchor_key, List.last(page).relative_path, acc)
    end
  end

  defp maybe_after_path(query, nil), do: query
  defp maybe_after_path(query, path), do: where(query, [c], c.relative_path > ^path)

  # --- Durable decisions -----------------------------------------------

  @doc """
  Dismisses a selection: stamps `dismissed_at` on every undismissed candidate
  in the selected anchors. Files are untouched.
  """
  @spec dismiss(SelectionScope.t()) :: {:ok, non_neg_integer()}
  def dismiss(%SelectionScope{} = scope) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      candidate_query(scope)
      |> where([c], is_nil(c.dismissed_at))
      |> Repo.update_all(set: [dismissed_at: now, updated_at: now])

    if count > 0, do: broadcast(scope.library_path_id)
    {:ok, count}
  end

  @doc """
  Restores a selection: clears `dismissed_at` on every dismissed candidate in
  the selected anchors.
  """
  @spec restore(SelectionScope.t()) :: {:ok, non_neg_integer()}
  def restore(%SelectionScope{} = scope) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      candidate_query(scope)
      |> where([c], not is_nil(c.dismissed_at))
      |> Repo.update_all(set: [dismissed_at: nil, updated_at: now])

    if count > 0, do: broadcast(scope.library_path_id)
    {:ok, count}
  end

  # The row-level (ungrouped) query for a scope's selected anchors, built by
  # reusing `SelectionScope.to_query/1` -- an aggregate query already scoped
  # to the right anchor keys -- as a subquery of matching keys. This keeps a
  # `:filter`-mode selection to one bounded query regardless of how many
  # groups it covers: no candidate id, and no anchor key, is ever pulled into
  # a bind-parameter list here.
  defp candidate_query(%SelectionScope{} = scope) do
    # `to_query/1` already carries a `select` (the aggregate map) -- Ecto
    # refuses a second `select` on the same query outright ("only one select
    # expression is allowed"), so the existing one has to be dropped before
    # this can reselect just the anchor key.
    anchor_keys =
      scope
      |> SelectionScope.to_query()
      |> exclude(:select)
      |> select([c], c.anchor_key)

    ImportCandidate
    |> where([c], c.library_path_id == ^scope.library_path_id)
    |> where([c], c.anchor_key in subquery(anchor_keys))
  end

  @doc """
  Applies a human-picked metadata match to every undismissed candidate in one
  anchor -- the "Change match" / "Identify" action.

  Each candidate's own `parsed_info` (season/episode) is left untouched; only
  the provider identity, title, year, media type, and confidence change.
  Confidence is set to 1.0: a human's pick is at least as trustworthy as an
  automatic match, and the point of a correction is that the group reads
  `:ready` afterwards.

  Returns `{:error, :not_found}` rather than raising when the anchor has no
  undismissed candidates left -- another session or a concurrent promotion can
  empty it between the page rendering the button and the reviewer clicking it.
  """
  @spec change_match(binary(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def change_match(library_path_id, anchor_key, match) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    match = stringify_match(match)

    {count, _} =
      ImportCandidate
      |> for_anchor(library_path_id, anchor_key)
      |> Repo.update_all(
        set: [
          provider_id: match.provider_id,
          provider_type: match.provider_type,
          title: match.title,
          year: match.year,
          media_type: match.media_type,
          confidence: 1.0,
          last_error: nil,
          attempts: 0,
          next_retry_at: nil,
          updated_at: now
        ]
      )

    if count > 0 do
      broadcast(library_path_id)
      {:ok, count}
    else
      {:error, :not_found}
    end
  end

  defp stringify_match(match) do
    %{
      provider_id: to_string(match.provider_id),
      provider_type: to_string(match.provider_type),
      title: match.title,
      year: match.year,
      media_type: to_string(match.media_type)
    }
  end

  @doc """
  Updates one candidate's assigned season and episode numbers.

  There is no group rollup to refresh: a group's `season_span` and
  `numbered_count` (as `band/1` and `group_query/2` see them) are computed
  fresh from `import_candidates` on every read, so nothing here needs
  invalidating.
  """
  @spec update_member_episode(
          binary(),
          integer() | String.t() | nil,
          integer() | String.t() | nil
        ) :: {:ok, ImportCandidate.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_member_episode(candidate_id, season, episode) do
    case Repo.get(ImportCandidate, candidate_id) do
      nil ->
        {:error, :not_found}

      candidate ->
        parsed_season = parse_int(season)
        episodes_list = if(ep = parse_int(episode), do: [ep], else: [])

        parsed_info =
          (candidate.parsed_info || %{})
          |> Map.put("season", parsed_season)
          |> Map.put("episodes", episodes_list)

        candidate
        |> ImportCandidate.changeset(%{parsed_info: parsed_info})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            broadcast(updated.library_path_id)
            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {val, ""} -> val
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  @doc """
  Accepts a selection: promotes every selected group whose candidates carry a
  real provider match, one group at a time.

  A group with no provider match (`:no_match`), or whose provider identity is
  the synthetic `"local"` marker (see `create_local_show/2`), has nothing for
  `Mydia.Library.CandidatePromotion` to enrich from and is skipped rather than
  attempted. Each accepted group's full membership is loaded in bounded pages
  (see `load_all_members/2`) and handed to `CandidatePromotion.promote_group/3`
  in one call, so the whole group's ownership change commits as the one
  transaction that function already guarantees -- this function opens no
  transaction of its own, and does no provider/network work inside one.
  """
  @spec accept(SelectionScope.t(), keyword()) ::
          {:ok, %{accepted: non_neg_integer(), skipped: non_neg_integer()}}
  def accept(%SelectionScope{} = scope, opts \\ []) do
    groups =
      scope
      |> SelectionScope.to_query()
      |> Repo.all()
      |> Enum.map(&to_group(&1, scope.status))

    result =
      Enum.reduce(groups, %{accepted: 0, skipped: 0}, fn group, acc ->
        case accept_group(group, opts) do
          {:ok, _media_files} -> %{acc | accepted: acc.accepted + 1}
          {:error, _reason} -> %{acc | skipped: acc.skipped + 1}
        end
      end)

    if result.accepted > 0, do: broadcast(scope.library_path_id)
    {:ok, result}
  end

  defp accept_group(%ImportCandidateGroup{provider_id: nil}, _opts), do: {:error, :no_match}

  defp accept_group(%ImportCandidateGroup{provider_type: "local"}, _opts),
    do: {:error, :local_show}

  defp accept_group(%ImportCandidateGroup{library_path_id: lp_id, anchor_key: key}, opts) do
    case load_all_members(lp_id, key) do
      [] ->
        {:error, :empty_group}

      candidates ->
        match = candidates |> List.first() |> ImportCandidate.to_match()
        CandidatePromotion.promote_group(candidates, match, opts)
    end
  end

  @doc """
  Accepts every pending provider-matched group for one library path.

  Unmatched and synthetic local groups are excluded by `accept/2` itself.
  Confidence is deliberately not filtered here: this is the explicit human
  override behind the review page's "Import all" control.
  """
  @spec accept_all_matched(binary(), keyword()) ::
          {:ok, %{accepted: non_neg_integer(), skipped: non_neg_integer()}}
  def accept_all_matched(library_path_id, opts \\ []) do
    library_path_id
    |> SelectionScope.new()
    |> SelectionScope.select_all_matching(%{})
    |> accept(opts)
  end

  @doc """
  Re-runs metadata matching for the candidates in a selection.

  Matches through `Mydia.Library.BatchMatcher` in bounded pages, writes each
  result back onto its candidate via `Mydia.Library.FileIngest.ingest/3` under
  the `:review` policy (write the verdict, never auto-promote), and broadcasts
  one change event after the whole pass -- not once per page or per file.
  """
  @spec rematch(SelectionScope.t(), keyword()) ::
          {:ok, %{files: non_neg_integer(), failures: non_neg_integer()}}
  def rematch(%SelectionScope{} = scope, opts \\ []) do
    library_path = Settings.get_library_path!(scope.library_path_id)
    matcher = Keyword.get(opts, :matcher, Mydia.Library.MetadataMatcher)
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()
    page_size = Keyword.get(opts, :page_size, 250)

    base_query = candidate_query(scope) |> where([c], is_nil(c.dismissed_at))

    stats =
      rematch_pages(base_query, library_path, matcher, config, page_size, nil, %{
        files: 0,
        failures: 0
      })

    broadcast(scope.library_path_id)

    {:ok, stats}
  end

  defp rematch_pages(base_query, library_path, matcher, config, page_size, after_id, stats) do
    rows =
      base_query
      |> maybe_after_id(after_id)
      |> order_by([c], asc: c.id)
      |> limit(^page_size)
      |> Repo.all()

    case rows do
      [] ->
        stats

      rows ->
        page_stats = rematch_rows(rows, library_path, matcher, config)
        stats = Map.merge(stats, page_stats, fn _key, left, right -> left + right end)

        rematch_pages(
          base_query,
          library_path,
          matcher,
          config,
          page_size,
          List.last(rows).id,
          stats
        )
    end
  end

  defp maybe_after_id(query, nil), do: query
  defp maybe_after_id(query, id), do: where(query, [c], c.id > ^id)

  defp rematch_rows(rows, library_path, matcher, config) do
    rows_by_path = Map.new(rows, &{Path.join(library_path.path, &1.relative_path), &1})

    rows_by_path
    |> Map.keys()
    |> BatchMatcher.match_paths(library_root: library_path.path, matcher: matcher, config: config)
    |> Enum.reduce(%{files: 0, failures: 0}, fn {path, outcome}, stats ->
      case rematch_candidate(rows_by_path[path], outcome) do
        :ok -> %{stats | files: stats.files + 1}
        :error -> %{stats | failures: stats.failures + 1}
      end
    end)
  end

  defp rematch_candidate(candidate, outcome) do
    case outcome do
      {:ok, match} ->
        ingest_stat(FileIngest.ingest(candidate, match, policy: :review))

      {:error, reason} when reason in [:no_match, :no_matches_found, :unknown_media_type] ->
        ingest_stat(FileIngest.ingest(candidate, nil, policy: :review))

      {:error, _reason} ->
        :error
    end
  rescue
    error ->
      Logger.error("Re-matching an import candidate failed",
        candidate_id: candidate.id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  end

  defp ingest_stat({:error, _reason}), do: :error
  defp ingest_stat(_result), do: :ok

  @doc """
  Clears the derived scan state for one library path: every undismissed
  candidate, plus finished import-run history.

  Dismissed candidates are preserved -- clearing is "re-match from scratch",
  not "discard every decision a human already made". Active runs are refused
  so their coordinator cannot recreate candidates while the clear is in
  progress.
  """
  @spec clear_for_library(binary()) ::
          {:ok, %{candidates: non_neg_integer()}} | {:error, :active_run}
  def clear_for_library(library_path_id) do
    result =
      Repo.transaction(fn ->
        active_statuses = ImportRun.active_statuses()

        if Repo.exists?(
             from(r in ImportRun,
               where: r.library_path_id == ^library_path_id and r.status in ^active_statuses
             )
           ) do
          Repo.rollback(:active_run)
        end

        {candidate_count, _} =
          ImportCandidate
          |> where([c], c.library_path_id == ^library_path_id and is_nil(c.dismissed_at))
          |> Repo.delete_all()

        ImportRun
        |> where([r], r.library_path_id == ^library_path_id)
        |> Repo.delete_all()

        %{candidates: candidate_count}
      end)

    with {:ok, counts} <- result do
      broadcast(library_path_id)
      {:ok, counts}
    end
  end

  @doc """
  Creates a local show from an anchor's folder name, for media no provider
  carries.

  There is no provider match for `CandidatePromotion` to enrich from, so this
  links members itself: it creates the show (no episode auto-fetch --
  episodes come from each candidate's own parsed season/episode numbers),
  inserts an owned `MediaFile` for every candidate whose numbering resolved,
  and deletes each one it successfully linked, all in one transaction.

  A candidate with no parsed episode number is left alone -- undismissed,
  visible, and still part of whatever the anchor's next read computes -- since
  there is nothing here that could number it.
  """
  @spec create_local_show(binary(), String.t()) :: {:ok, Media.MediaItem.t()} | {:error, term()}
  def create_local_show(library_path_id, anchor_key) do
    Repo.transaction(fn -> create_local_show_transaction(library_path_id, anchor_key) end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_local_show_transaction(library_path_id, anchor_key) do
    case load_all_members(library_path_id, anchor_key) do
      [] ->
        {:error, :not_found}

      candidates ->
        {title, year} = title_and_year(anchor_key)

        case Media.create_media_item(
               %{title: title, year: year, type: "tv_show", monitored: false},
               skip_episode_refresh: true
             ) do
          {:ok, item} ->
            Enum.each(candidates, &link_local_candidate(&1, item))
            broadcast(library_path_id)
            {:ok, item}

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  # `anchor_key` is already normalized (lowercased, punctuation and any
  # `(YYYY)` year stripped) by `Mydia.Library.PathAnchor.normalize/1`, so
  # -- unlike parsing a year out of the original folder text -- there is no
  # year left to recover here. `humanize/1` title-cases the key back into
  # something presentable; the year is accepted as lost.
  defp title_and_year(anchor_key), do: {humanize(anchor_key), nil}

  defp link_local_candidate(%ImportCandidate{} = candidate, item) do
    with %{} = parsed <- candidate.parsed_info,
         season when is_integer(season) <- Map.get(parsed, "season"),
         [number | _] <- Map.get(parsed, "episodes") || [] do
      episode =
        Repo.get_by(Episode,
          media_item_id: item.id,
          season_number: season,
          episode_number: number
        ) ||
          create_local_episode(item, season, number, candidate)

      if episode, do: insert_local_file(candidate, episode)
    else
      _ -> :ok
    end
  end

  defp create_local_episode(item, season, number, candidate) do
    case Media.create_episode(%{
           media_item_id: item.id,
           season_number: season,
           episode_number: number,
           title: Path.rootname(Path.basename(candidate.relative_path))
         }) do
      {:ok, episode} -> episode
      {:error, _changeset} -> nil
    end
  end

  defp insert_local_file(candidate, episode) do
    attrs = %{
      episode_id: episode.id,
      library_path_id: candidate.library_path_id,
      relative_path: candidate.relative_path,
      size: candidate.size,
      verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case %MediaFile{} |> MediaFile.changeset(attrs) |> Repo.insert() do
      {:ok, _media_file} -> Repo.delete(candidate)
      {:error, _changeset} -> :ok
    end
  end

  defp broadcast(library_path_id) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "import_candidates:#{library_path_id}",
      {:import_candidates_changed, library_path_id}
    )
  end

  # --- internal helpers ----------------------------------------------------

  defp insert_or_update(candidate, attrs, library_path_id, relative_path) do
    case candidate |> ImportCandidate.changeset(attrs) |> Repo.insert_or_update() do
      {:error, %Ecto.Changeset{} = changeset} ->
        case Repo.get_by(ImportCandidate,
               library_path_id: library_path_id,
               relative_path: relative_path
             ) do
          nil -> {:error, changeset}
          existing -> existing |> ImportCandidate.changeset(attrs) |> Repo.update()
        end

      result ->
        result
    end
  end

  defp provider_identity(%{metadata_source: :tmdb, tmdb_id: id}) when not is_nil(id),
    do: {"tmdb", Integer.to_string(id)}

  defp provider_identity(%{metadata_source: :tvdb, tvdb_id: id}) when not is_nil(id),
    do: {"tvdb", Integer.to_string(id)}

  defp provider_identity(%{metadata_source: :tmdb}), do: {"tmdb", nil}
  defp provider_identity(%{metadata_source: :tvdb}), do: {"tvdb", nil}

  defp provider_identity(%{tvdb_id: id}) when not is_nil(id), do: {"tvdb", Integer.to_string(id)}
  defp provider_identity(%{tmdb_id: id}) when not is_nil(id), do: {"tmdb", Integer.to_string(id)}
  defp provider_identity(_), do: {nil, nil}
end
