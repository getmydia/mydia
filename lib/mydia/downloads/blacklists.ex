defmodule Mydia.Downloads.Blacklists do
  @moduledoc """
  Context for the release blacklist (issue #123).

  Public API:

    * `add/4` — insert (or upsert) a `(indexer, guid)` blacklist row. The
      default TTL is sourced from `Mydia.Config.Schema.Downloads.release_blacklist_default_ttl_days`
      (defaults to 30 days when unset). Pass `expires_at: nil` to block forever.
    * `blacklisted?/2` — `true` when an unexpired (or "forever") row exists.
    * `list/1` — admin-facing listing with optional `:failure_reason` filter
      and `:limit` / `:offset` for pagination.
    * `remove/1` — delete a row by id (admin "un-blacklist").
    * `cleanup_expired/0` — purge rows whose `expires_at` is in the past;
      driven by `Mydia.Jobs.BlacklistCleanup`.

  ## Guid plumbing

  The blacklist key is `(indexer, guid)`. Some indexers return a stable
  `guid` per release; others don't. The producer (`DownloadMonitor`) is
  responsible for materializing a fallback guid — typically a SHA-256 of
  `(indexer, title, size)` — when one is missing. This module performs no
  fallback synthesis of its own.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.Repo

  require Logger

  @default_ttl_days 30

  @type add_opts :: [
          expires_at: DateTime.t() | nil,
          ttl_days: non_neg_integer() | nil
        ]

  @doc """
  Pulls the `(indexer, guid)` blacklist key off a download.

  The indexer is read from the column first and falls back to the copy stored
  in `metadata`, which is where older rows carry it.
  """
  @spec extract_key(Mydia.Downloads.Download.t()) ::
          {:ok, String.t(), String.t()} | {:error, :no_indexer | :no_guid}
  def extract_key(download) do
    indexer = download.indexer || get_in(download.metadata || %{}, ["indexer"])
    guid = get_in(download.metadata || %{}, ["guid"])

    cond do
      is_nil(indexer) or indexer == "" -> {:error, :no_indexer}
      is_nil(guid) or guid == "" -> {:error, :no_guid}
      true -> {:ok, indexer, guid}
    end
  end

  @doc """
  Inserts a blacklist row, upserting on `(indexer, guid)` conflicts.

  Options:

    * `:expires_at` — explicit timestamp. `nil` means block forever. When
      omitted, defaults to `now + ttl_days` days.
    * `:ttl_days` — number of days until expiry. Defaults to the configured
      `release_blacklist_default_ttl_days` (30 if unset). Ignored when
      `:expires_at` is supplied.

  Returns `{:ok, %ReleaseBlacklist{}}` on success.
  """
  @spec add(String.t(), String.t(), String.t(), String.t(), add_opts()) ::
          {:ok, ReleaseBlacklist.t()} | {:error, Ecto.Changeset.t()}
  def add(indexer, guid, title, failure_reason, opts \\ [])
      when is_binary(indexer) and is_binary(guid) and is_binary(title) and
             is_binary(failure_reason) do
    now = DateTime.utc_now()

    expires_at = resolve_expires_at(now, opts)

    attrs = %{
      indexer: indexer,
      guid: guid,
      title: title,
      failure_reason: failure_reason,
      expires_at: expires_at,
      inserted_at: now
    }

    %ReleaseBlacklist{}
    |> ReleaseBlacklist.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          title: title,
          failure_reason: failure_reason,
          expires_at: expires_at,
          inserted_at: now
        ]
      ],
      conflict_target: [:indexer, :guid]
    )
  end

  @doc """
  Returns `true` when an active blacklist row exists for `(indexer, guid)`.

  A row is "active" when:

    * `expires_at` is `nil` (blocked forever), or
    * `expires_at` is in the future.

  Expired rows are treated as if absent — they're swept by
  `cleanup_expired/0` eventually.
  """
  @spec blacklisted?(String.t() | nil, String.t() | nil) :: boolean()
  def blacklisted?(indexer, guid)
      when is_binary(indexer) and is_binary(guid) do
    normalized = ReleaseBlacklist.normalize_indexer(indexer)
    now = DateTime.utc_now()

    query =
      from b in ReleaseBlacklist,
        where: b.indexer == ^normalized and b.guid == ^guid,
        where: is_nil(b.expires_at) or b.expires_at > ^now,
        select: 1,
        limit: 1

    Repo.exists?(query)
  end

  def blacklisted?(_, _), do: false

  @doc """
  Filters out results whose `(indexer, guid)` is currently blacklisted, in
  one DB roundtrip regardless of result-list size.

  Each search result is expected to expose `:indexer` and `:guid` keys.
  Results missing either are kept (no blacklist key to compare). Rejected
  rows are logged at `:info` along with the supplied `log_context` keyword
  list so callers can attach episode/movie ids for traceability.

  ## Examples

      iex> Mydia.Downloads.Blacklists.reject_blacklisted(results, episode_id: ep.id)
      [...]
  """
  @spec reject_blacklisted([map()], Keyword.t()) :: [map()]
  def reject_blacklisted(results, log_context \\ []) when is_list(results) do
    blacklisted = batch_blacklisted(results)

    Enum.filter(results, fn result ->
      pair = blacklist_key(result)

      if pair && MapSet.member?(blacklisted, pair) do
        Logger.info(
          "Rejected blacklisted release",
          [indexer: result.indexer, guid: result.guid, title: Map.get(result, :title)] ++
            log_context
        )

        false
      else
        true
      end
    end)
  end

  defp batch_blacklisted(results) do
    pairs =
      results
      |> Enum.map(&blacklist_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case pairs do
      [] ->
        MapSet.new()

      pairs ->
        now = DateTime.utc_now()
        # Normalize once so the DB compares against the canonical form.
        normalized_pairs =
          Enum.map(pairs, fn {indexer, guid} ->
            {ReleaseBlacklist.normalize_indexer(indexer), guid}
          end)

        # SQLite's Ecto adapter doesn't support tuple `IN` predicates, so we
        # fetch by `indexer IN (...)` + `guid IN (...)` and intersect with the
        # candidate pair set in Elixir. The set of pairs in a single search is
        # bounded (~50), so the over-fetch is negligible.
        indexers = normalized_pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        guids = normalized_pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        query =
          from b in ReleaseBlacklist,
            where: b.indexer in ^indexers and b.guid in ^guids,
            where: is_nil(b.expires_at) or b.expires_at > ^now,
            select: {b.indexer, b.guid}

        candidate = MapSet.new(normalized_pairs)

        Repo.all(query)
        |> MapSet.new()
        |> MapSet.intersection(candidate)
    end
  end

  defp blacklist_key(%{indexer: indexer, guid: guid})
       when is_binary(indexer) and is_binary(guid) and guid != "" do
    {ReleaseBlacklist.normalize_indexer(indexer), guid}
  end

  defp blacklist_key(_), do: nil

  @doc """
  Lists blacklist rows, newest first.

  Options:

    * `:failure_reason` — exact-match filter on the failure tag.
    * `:limit` — page size (default 50).
    * `:offset` — pagination offset (default 0).
  """
  @spec list(keyword()) :: [ReleaseBlacklist.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    failure_reason = Keyword.get(opts, :failure_reason)

    query =
      from b in ReleaseBlacklist,
        order_by: [desc: b.inserted_at],
        limit: ^limit,
        offset: ^offset

    query =
      if is_binary(failure_reason) and failure_reason != "" do
        from b in query, where: b.failure_reason == ^failure_reason
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Counts blacklist rows matching the optional `:failure_reason` filter.

  Used by the admin LiveView for pagination totals.
  """
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    failure_reason = Keyword.get(opts, :failure_reason)

    query = from(b in ReleaseBlacklist, select: count(b.id))

    query =
      if is_binary(failure_reason) and failure_reason != "" do
        from b in query, where: b.failure_reason == ^failure_reason
      else
        query
      end

    Repo.one(query) || 0
  end

  @doc """
  Returns the distinct failure reasons currently present. Useful for the
  admin filter dropdown.
  """
  @spec list_failure_reasons() :: [String.t()]
  def list_failure_reasons do
    Repo.all(
      from b in ReleaseBlacklist,
        distinct: true,
        select: b.failure_reason,
        order_by: b.failure_reason
    )
  end

  @doc """
  Fetches a single blacklist row by id. Raises if not found.
  """
  @spec get!(binary()) :: ReleaseBlacklist.t()
  def get!(id), do: Repo.get!(ReleaseBlacklist, id)

  @doc """
  Removes a blacklist row by id. Returns `{:ok, row}` or `{:error, :not_found}`.
  """
  @spec remove(binary()) :: {:ok, ReleaseBlacklist.t()} | {:error, :not_found}
  def remove(id) when is_binary(id) do
    case Repo.get(ReleaseBlacklist, id) do
      nil ->
        {:error, :not_found}

      row ->
        Repo.delete(row)
    end
  end

  @doc """
  Sets `expires_at` to `nil` (block forever) for the row with `id`.

  Returns `{:ok, row}` or `{:error, :not_found | changeset}`.
  """
  @spec block_forever(binary()) ::
          {:ok, ReleaseBlacklist.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def block_forever(id) when is_binary(id) do
    case Repo.get(ReleaseBlacklist, id) do
      nil ->
        {:error, :not_found}

      row ->
        row
        |> Changeset.change(expires_at: nil)
        |> Repo.update()
    end
  end

  @doc """
  Deletes all blacklist rows whose `expires_at` is in the past.

  Returns the number of rows removed.
  """
  @spec cleanup_expired() :: non_neg_integer()
  def cleanup_expired do
    now = DateTime.utc_now()

    {deleted, _} =
      Repo.delete_all(
        from b in ReleaseBlacklist,
          where: not is_nil(b.expires_at) and b.expires_at <= ^now
      )

    deleted
  end

  # --- private helpers ---------------------------------------------------

  defp resolve_expires_at(now, opts) do
    case Keyword.fetch(opts, :expires_at) do
      {:ok, value} ->
        # Explicit nil = forever; explicit DateTime = use as-is.
        value

      :error ->
        days = Keyword.get(opts, :ttl_days) || default_ttl_days()
        DateTime.add(now, days * 24 * 60 * 60, :second)
    end
  end

  defp default_ttl_days do
    case Application.get_env(:mydia, :runtime_config) do
      %{downloads: %{release_blacklist_default_ttl_days: days}}
      when is_integer(days) and days > 0 ->
        days

      _ ->
        @default_ttl_days
    end
  end
end
