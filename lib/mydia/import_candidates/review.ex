defmodule Mydia.ImportCandidates.Review do
  @moduledoc false

  import Ecto.Query

  alias Mydia.ImportCandidates
  alias Mydia.ImportCandidates.Store
  alias Mydia.Library.{ImportCandidate, ImportCandidateGroup, ImportRun}
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  # The confidence at or above which a group is considered settled.
  #
  # See `Mydia.Library.FileIngest.default_threshold/0`, which reads the same
  # number for the analogous unattended-import decision. Both are pinned at
  # 0.85 by design; they are not derived from one another so that this module
  # does not carry a compile-time dependency on `FileIngest`.
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

  # --- Grouped read model -------------------------------------------------

  @doc "The confidence at or above which a group is considered settled."
  @spec auto_accept_threshold() :: float()
  def auto_accept_threshold, do: @auto_accept_threshold

  @doc """
  Which review band a group falls into.

  Mirrors the `HAVING` predicates `group_query/2` applies in SQL: `:needs_attention`
  is built as the logical complement of `:no_match` and `:ready` in both places
  (`needs_attention_condition/0` below, and this function's fallback `cond`
  clause), specifically so the two cannot drift into disagreeing about a group
  that is genuinely neither -- a `provider_type: "local"` group with a single
  agreeing provider at or above the threshold was exactly that case: excluded
  from `:ready` by the local carve-out, excluded from `:no_match` because it
  has a provider id, and (before this) also excluded from a `:needs_attention`
  predicate that only recognised disagreement or low confidence as reasons to
  land there. That gap made such a group invisible to `band_counts/1`'s total
  and to any band-filtered `page/2`/`SelectionScope` selection, even though
  this function has always called it `:needs_attention` via its explicit
  `provider_type: "local"` clause below. `import_candidates_test.exs` proves
  the two paths agree, including for that exact shape.

  A group holding a returned candidate (`returned_count > 0`) is never ready
  either. An operator sent that file back from an item it was wrongly filed
  under, and a confident suggestion can name that same item, so a person has
  to look at it. `ready_condition/0` carries the same rule in SQL.
  """
  @spec band(ImportCandidateGroup.t()) :: :ready | :needs_attention | :no_match
  def band(%ImportCandidateGroup{provider_id: nil}), do: :no_match
  def band(%ImportCandidateGroup{provider_type: "local"}), do: :needs_attention

  def band(%ImportCandidateGroup{returned_count: count}) when is_integer(count) and count > 0,
    do: :needs_attention

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

  `:status` (default `"pending"`) is `"pending"`, `"queued"`, or anything else
  for dismissed. `:band` and `:q` apply the same predicates `page/2` exposes.
  """
  @spec group_query(binary(), keyword()) :: Ecto.Query.t()
  def group_query(library_path_id, opts \\ []) do
    status = Keyword.get(opts, :status, "pending")

    ImportCandidate
    |> where([c], c.library_path_id == ^library_path_id)
    |> filter_status(status)
    |> aggregate_group_query()
    |> apply_band(Keyword.get(opts, :band))
    |> apply_search(Keyword.get(opts, :q))
  end

  # The anchor-key rollup `group_query/2` and `queued_group/3` both build on:
  # groups an already-scoped base query by anchor, aggregating `count(id)`,
  # `min(confidence)`, and `count(distinct provider_id)` alongside
  # representative (`max/1`) provider/title/type values. Every row this
  # returns is a plain map; convert it with the private `to_group/2`.
  defp aggregate_group_query(query) do
    query
    # `library_path_id` is constant across every row here (the caller's WHERE
    # clause already pins it), but PostgreSQL still requires a plain
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
      media_type: max(c.media_type),
      queued_op: max(c.queued_op),
      queue_error: max(c.queue_error),
      returned_count: count(c.returned_at)
    })
  end

  # Three mutually exclusive states over two nullable columns. A queued row is
  # never dismissed (AcceptQueue.queue_accept/2 and Rematch.queue_rematch/1 only
  # mark undismissed rows) and a dismissed row is never queued (Edits.dismiss/1
  # skips queued rows), so
  # "pending" has to exclude both while the other two each name one.
  @doc false
  def filter_status(query, "pending"),
    do: where(query, [c], is_nil(c.dismissed_at) and is_nil(c.queued_op))

  def filter_status(query, "queued"),
    do: where(query, [c], is_nil(c.dismissed_at) and not is_nil(c.queued_op))

  def filter_status(query, _status), do: where(query, [c], not is_nil(c.dismissed_at))

  defp apply_band(query, nil), do: query
  defp apply_band(query, :all), do: query

  defp apply_band(query, :no_match) do
    having(query, [c], ^no_match_condition())
  end

  defp apply_band(query, :ready) do
    having(query, [c], ^ready_condition())
  end

  # Built as the logical complement of the other two bands, not as its own
  # independent predicate, so the three can never fail to partition the data:
  # every group is :no_match, :ready, or (by construction) neither, and
  # "neither" is exactly what :needs_attention means. A hand-derived version
  # of this predicate (disagreement or low confidence) is what let a
  # `provider_type: "local"` group with a single agreeing high-confidence
  # provider -- excluded from :ready by the local carve-out, but not
  # disagreeing and not low-confidence -- match none of the three bands at
  # all. See `band/1`'s doc for the full story.
  defp apply_band(query, :needs_attention) do
    having(query, [c], ^needs_attention_condition())
  end

  # A pinned `dynamic/2` value may only be interpolated at the top level of a
  # `having`/`where` (or combined with other pinned dynamics inside a fresh
  # `dynamic/2` call) -- not nested under `not (...)` directly inside
  # `having/3`. So the complement is built as its own dynamic here and handed
  # to `having/3` as one single top-level interpolation, rather than trying to
  # negate and combine `no_match_condition/0` and `ready_condition/0` inline.
  defp needs_attention_condition do
    no_match = no_match_condition()
    ready = ready_condition()

    dynamic([c], not (^no_match) and not (^ready))
  end

  defp no_match_condition, do: dynamic([c], is_nil(max(c.provider_id)))

  defp ready_condition do
    threshold = @auto_accept_threshold

    dynamic(
      [c],
      count(c.provider_id, :distinct) == 1 and
        fragment("COALESCE(?, 0.0)", min(c.confidence)) >= ^threshold and
        (is_nil(max(c.provider_type)) or max(c.provider_type) != "local") and
        count(c.returned_at) == 0
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

  @doc false
  def escape_like(term) do
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
  @spec page(binary(), keyword()) :: {[ImportCandidateGroup.t()], ImportCandidates.cursor() | nil}
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

  @doc """
  One group's current aggregate row, or `nil` if the anchor has no candidates
  matching `opts`.

  Reuses `group_query/2` -- the same aggregate `page/2` builds from -- rather
  than hand-rolling a second aggregate, so a single-group refresh can never
  drift from `page/2`'s band, status, and search semantics. Accepts the same
  `:status` and `:band` options as `page/2`; a caller refreshing one row after
  a mutation should pass whatever `:status` the surrounding view is showing.
  """
  @spec get_group(binary(), String.t(), keyword()) :: ImportCandidateGroup.t() | nil
  def get_group(library_path_id, anchor_key, opts \\ []) do
    status = Keyword.get(opts, :status, "pending")

    library_path_id
    |> group_query(status: status, band: Keyword.get(opts, :band), q: Keyword.get(opts, :q))
    |> where([c], c.anchor_key == ^anchor_key)
    |> Repo.one()
    |> case do
      nil -> nil
      row -> to_group(row, status)
    end
  end

  # One anchor's aggregate row, scoped to rows queued for exactly `op` --
  # unlike `get_group(..., status: "queued")`, which matches *any* queued_op
  # via `filter_status/2`. An anchor can carry rows queued for different ops
  # at once (a scan can insert a pending row under an already-queued anchor,
  # and a second `queued_op` value queues its own subset later), so computing
  # one op's promotion eligibility (`provider_id`, `provider_count`,
  # `provider_type`) from the broader "any queued_op" aggregate would compute
  # it over a superset of what actually gets promoted. Kept separate from
  # `get_group/3` rather than folded into it, since `get_group/3` has other
  # callers that depend on its existing `:status` semantics.
  @doc false
  def queued_group(library_path_id, anchor_key, op) do
    library_path_id
    |> queued_query(op)
    |> where([c], c.anchor_key == ^anchor_key)
    |> aggregate_group_query()
    |> Repo.one()
    |> case do
      nil -> nil
      row -> to_group(row, "queued")
    end
  end

  # The op predicate every queued-drain query shares: undismissed rows on one
  # library path, queued for exactly one op. Never loosen this to "any
  # queued_op" the way `filter_status(query, "queued")` is for the review
  # page's status filter -- an anchor can hold rows queued for different ops
  # at once, and each op's drain must see only its own subset.
  @doc false
  def queued_query(library_path_id, op) do
    ImportCandidate
    |> where([c], c.library_path_id == ^library_path_id and c.queued_op == ^op)
    |> where([c], is_nil(c.dismissed_at))
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
      dismissed?: status == "ignored",
      queued?: status == "queued",
      queue_error: row.queue_error,
      returned_count: row.returned_count
    }
  end

  defp display_title(%{anchor_key: "__root__"}), do: "Loose files"
  defp display_title(%{suggested_title: title}) when is_binary(title) and title != "", do: title
  defp display_title(%{anchor_key: key}), do: humanize(key)

  @doc false
  def humanize(key) do
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
    |> where([c], is_nil(c.dismissed_at) and is_nil(c.queued_op))
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

  @doc false
  def for_anchor(query, library_path_id, anchor_key) do
    where(
      query,
      [c],
      c.library_path_id == ^library_path_id and c.anchor_key == ^anchor_key and
        is_nil(c.dismissed_at)
    )
  end

  # --- Match-phase discovery ------------------------------------------------

  @doc """
  Keyset page of candidates still needing a match attempt, for `Jobs.ImportRun`'s
  match loop.

  A candidate is outstanding when it is undismissed, carries no provider match
  yet, and either has never failed before or its backoff (`next_retry_at`) has
  already passed. A candidate leaves this set the moment `FileIngest` records a
  match, a retry timestamp, or `Edits.dismiss/1` stamps it -- and it stops existing
  at all once `CandidatePromotion` promotes it, so every one of the four exits
  `Jobs.ImportRun`'s moduledoc promises removes a row from here for good (a
  retry timestamp only removes it until the backoff elapses, which is the
  intended, time-bounded re-entry, not a bug).

  Returns `%ImportCandidate{}` structs with `:library_path` preloaded, so a
  caller can build each one's absolute path via `ImportCandidate.absolute_path/1`
  without a second query per row.

  ## Options

    * `:after` - keyset cursor. When set, only rows with `id` greater than
      this are considered, matching the `:after_id` convention `Jobs.ImportRun`
      already uses elsewhere.
  """
  @spec outstanding(binary(), pos_integer(), keyword()) :: [ImportCandidate.t()]
  def outstanding(library_path_id, limit, opts \\ []) do
    library_path_id
    |> outstanding_query()
    |> maybe_after_id(Keyword.get(opts, :after))
    |> order_by([c], asc: c.id)
    |> limit(^limit)
    |> preload(:library_path)
    |> Repo.all()
  end

  @doc """
  Counts every outstanding candidate for one library path (see `outstanding/3`).

  Deliberately not `length(outstanding(library_path_id, :infinity))`: this is
  `Jobs.ImportRun.verify_match_phase_complete/2`'s completion backstop, run
  once per match phase, and must stay a single aggregate query regardless of
  how large the outstanding set is.
  """
  @spec count_outstanding(binary()) :: non_neg_integer()
  def count_outstanding(library_path_id) do
    library_path_id
    |> outstanding_query()
    |> Repo.aggregate(:count)
  end

  defp outstanding_query(library_path_id) do
    now = Store.now()

    ImportCandidate
    |> where([c], c.library_path_id == ^library_path_id)
    |> where([c], is_nil(c.dismissed_at))
    |> where([c], is_nil(c.provider_id))
    |> where([c], is_nil(c.next_retry_at) or c.next_retry_at <= ^now)
  end

  @doc false
  def maybe_after_id(query, nil), do: query
  def maybe_after_id(query, id), do: where(query, [c], c.id > ^id)

  # Walks a whole group's undismissed candidates in keyset pages of
  # `@member_page_size` (500), so a group the size of a full season tree is never
  # one unbounded allocation, while still handing callers
  # (`AcceptQueue.load_queued_members/3`, `AcceptQueue.load_pending_members/2`)
  # the complete membership they need to act on the
  # group as a single unit.
  @doc false
  def load_all_members(library_path_id, anchor_key),
    do: load_all_members(library_path_id, anchor_key, nil, [])

  defp load_all_members(library_path_id, anchor_key, after_path, acc) do
    page =
      ImportCandidate
      |> for_anchor(library_path_id, anchor_key)
      |> maybe_after_path(after_path)
      |> order_by([c], asc: c.relative_path)
      |> limit(^@member_page_size)
      |> Repo.all()

    if length(page) < @member_page_size do
      [page | acc] |> Enum.reverse() |> Enum.concat()
    else
      load_all_members(library_path_id, anchor_key, List.last(page).relative_path, [page | acc])
    end
  end

  defp maybe_after_path(query, nil), do: query
  defp maybe_after_path(query, path), do: where(query, [c], c.relative_path > ^path)
end
