defmodule Mydia.Media.ExternalIds do
  @moduledoc """
  Decides which provider ids an attrs map may safely take.

  `media_items` carries a unique index on `(type, tmdb_id)` and another on
  `(type, tvdb_id)`, so writing a provider id another row of the same type
  already holds turns an ordinary metadata refresh into a constraint error.
  TMDB and TVDB number movies and series independently, so a movie and a show
  may hold the same number without conflicting, and every lookup here is scoped
  by `:type` for that reason. Every path that learns a second provider id for an
  item goes through `put_free_ids/3`, which adds only the ids no other row of
  the same type already owns and reports the ones it skipped.

  A skipped id means the library holds two rows for one title. That is worth
  telling the operator about, so it becomes a warning event on the activity
  timeline rather than a log line nobody reads. Rows are never merged or
  deleted here; which one to keep is the operator's call.
  """

  require Logger

  alias Mydia.Events
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  @type t :: %{
          tmdb: integer() | nil,
          tvdb: integer() | nil,
          imdb: String.t() | nil
        }

  @providers [:tmdb, :tvdb]

  @doc """
  Adds the free provider ids from `external_ids` to `attrs`.

  A key already present in `attrs` with a non-nil value always wins: the
  caller's own primary id is authoritative and this function only fills gaps.
  `:imdb` is not considered, because no unique index covers `imdb_id` and it
  flows through the ordinary `metadata.imdb_id` assignment already.

  ## Options

    * `:type` - required. `"movie"` or `"tv_show"`. Provider ids are unique
      per type, so an unscoped lookup reports a movie as the owner of a show's
      id. It is an explicit option rather than a read of `attrs[:type]` because
      two call sites pass a bare changes map that has no `:type` key, and both
      write to rows that already exist, where a silent fallback does the most
      damage.
    * `:exclude_id` - id of the media item being updated. A row writing its own
      id back is not a conflict.
    * `:title` - title used in the warning when a conflict is reported.
      Defaults to `attrs[:title]`.
  """
  @spec put_free_ids(map(), t() | nil, keyword()) :: map()
  def put_free_ids(attrs, external_ids, opts \\ [])

  def put_free_ids(attrs, nil, opts) do
    # No ids to place, so the binding is unused. `fetch_type!/1` is still
    # called for its raising side effect: a caller with no external_ids must
    # still be required to pass a valid :type, the same as every other clause.
    _type = fetch_type!(opts)
    attrs
  end

  def put_free_ids(attrs, external_ids, opts) when is_map(external_ids) do
    type = fetch_type!(opts)

    Enum.reduce(@providers, attrs, fn provider, acc ->
      put_free_id(acc, provider, Map.get(external_ids, provider), type, opts)
    end)
  end

  defp put_free_id(attrs, _provider, nil, _type, _opts), do: attrs

  defp put_free_id(attrs, provider, id, type, opts) do
    key = attrs_key(provider)

    if is_nil(Map.get(attrs, key)) do
      case conflicting_item(provider, id, type, opts[:exclude_id]) do
        nil -> Map.put(attrs, key, id)
        other -> report_conflict(attrs, provider, id, other, opts)
      end
    else
      attrs
    end
  end

  defp attrs_key(:tmdb), do: :tmdb_id
  defp attrs_key(:tvdb), do: :tvdb_id

  defp fetch_type!(opts) do
    type = Keyword.get(opts, :type)

    if type in MediaItem.valid_types() do
      type
    else
      raise ArgumentError,
            "Mydia.Media.ExternalIds requires a :type option, one of " <>
              "#{inspect(MediaItem.valid_types())}, got: #{inspect(type)}"
    end
  end

  defp conflicting_item(provider, id, type, exclude_id) do
    case Media.find_by_external_ids(%{provider => id}, type: type) do
      nil -> nil
      %{id: ^exclude_id} -> nil
      item -> item
    end
  end

  @doc """
  Runs a write that may still collide on a provider id, and degrades a
  collision into the same warning flow `put_free_ids/3` produces.

  `put_free_ids/3` reads ownership and the caller writes afterwards. Two writers
  can both see an id as free and the loser fails on the unique index with a raw
  constraint error rather than the controlled duplicate-provider result.

  A transaction does not close that. At PostgreSQL's default `READ COMMITTED`
  both writers still read the id as free and one still fails at write time, and
  SQLite's deferred transactions behave the same. Catching the constraint error
  and re-reading is what does the work, and it covers stale reads seconds old
  rather than only the instant.

  On a provider-id unique-constraint error, every provider id present in
  `attrs` is re-checked live and the ones still taken are looked up, reported
  and dropped in a single pass, then `fun` runs once more. The database only
  ever reports the first index it aborts on, never a second one from the same
  attempt, so dropping only that one id and retrying could still collide on
  another; checking every present id in the same pass instead means one retry
  always suffices, because after the pass no provider index can collide. A
  second collision on the retry needs a third writer claiming the other id
  between the two attempts, and returns the changeset unchanged.

  Anything that is not a provider-id unique-constraint error, including ordinary
  validation failures, passes straight through.

  ## Ambient transactions

  `fun` may run inside a transaction the caller already opened (the enricher's
  `persist_in_transaction/1`, or `MediaRequests.insert_approval/4`'s
  `Multi.run` + `Repo.transaction`). On PostgreSQL, a statement that fails a
  constraint check aborts the whole transaction at the database level
  (SQLSTATE `25P02`, `in_failed_sql_transaction`): Ecto still returns
  `{:error, changeset}` for that call, but every later query on the same
  connection then raises until an explicit rollback. The re-read this function
  does right after a collision is exactly such a later query, so every attempt
  of `fun` runs inside its own savepoint, released on success and rolled back
  to (not just released) on error -- releasing a savepoint whose statement
  already failed does not clear the aborted state, only `ROLLBACK TO SAVEPOINT`
  does. SQLite has no equivalent whole-transaction abort, so this only matters
  on PostgreSQL, and the savepoint dance is a harmless no-op there. This is a
  savepoint for error recovery around one write attempt, a different concern
  from the "no transaction" note above about not using a transaction to close
  the check-then-write race, and does not reintroduce it.

  ## Options

  The same `:type` (required), `:exclude_id` and `:title` as `put_free_ids/3`.
  """
  @spec write(map(), keyword(), (map() -> {:ok, term()} | {:error, Ecto.Changeset.t()})) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()}
  def write(attrs, opts, fun) when is_function(fun, 1) do
    type = fetch_type!(opts)

    case attempt(fun, attrs) do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if provider_id_conflict?(changeset) do
          attempt(fun, drop_taken(attrs, type, opts))
        else
          error
        end

      other ->
        other
    end
  end

  # Outside an ambient transaction this is exactly `fun.(attrs)`. Inside one,
  # wraps the attempt in a savepoint so a constraint failure unwinds only to
  # the savepoint rather than aborting the whole ambient transaction.
  #
  # `Repo.transaction(fn -> fun.(attrs) end, mode: :savepoint)` looks like the
  # idiomatic way to ask Ecto for that savepoint, but it is not: when already
  # inside a transaction in the same process, `Ecto.Adapters.SQL` hands
  # `DBConnection.transaction/3` the same connection struct the outer
  # transaction stored, already tagged `conn_mode: :transaction`, and
  # `DBConnection.transaction/3` special-cases that by running the function
  # directly and discarding `opts` entirely -- no SAVEPOINT is ever issued.
  # Calling `Repo.rollback/1` inside that nested call is worse than doing
  # nothing: verified empirically against PostgreSQL, it throws past the
  # nested call, matches nothing that would catch it there, and disconnects
  # the connection outright (`DBConnection.ConnectionError: transaction rolling
  # back`). Ecto's own `mode: :savepoint` option is for a single
  # `Repo.insert/update/delete` call, not for wrapping an enclosing
  # `Repo.transaction`, and `fun` here is an opaque closure this module does
  # not control the internals of, so that option has nowhere to attach.
  # Issuing the SAVEPOINT / ROLLBACK TO SAVEPOINT / RELEASE SAVEPOINT
  # statements directly, as below, is what actually works, verified the same
  # way (`ROLLBACK TO SAVEPOINT` genuinely clears the aborted state, and the
  # ambient transaction still holds every earlier write in the same test run).
  defp attempt(fun, attrs) do
    if Repo.in_transaction?() do
      attempt_with_savepoint(fun, attrs)
    else
      fun.(attrs)
    end
  end

  defp attempt_with_savepoint(fun, attrs) do
    Repo.query!("SAVEPOINT external_ids_write")

    case fun.(attrs) do
      {:error, _} = error ->
        Repo.query!("ROLLBACK TO SAVEPOINT external_ids_write")
        Repo.query!("RELEASE SAVEPOINT external_ids_write")
        error

      ok ->
        # RELEASE only merges the savepoint's writes back into the still-open
        # ambient transaction; it commits nothing on its own. The ambient
        # transaction commits or rolls back as a whole, same as if this
        # savepoint had never existed.
        Repo.query!("RELEASE SAVEPOINT external_ids_write")
        ok
    end
  end

  defp provider_id_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(@providers, fn provider ->
      key = attrs_key(provider)

      Enum.any?(errors, fn
        {^key, {_message, meta}} -> Keyword.get(meta, :constraint) == :unique
        _ -> false
      end)
    end)
  end

  # A failed write only ever names one violated index, never both at once, so
  # the retry re-checks every provider id present in `attrs` rather than only
  # the one the database happened to report. Anything still nil after that
  # re-check was never a candidate and is left alone.
  #
  # The live re-read decides each remaining id on its own: finding an owner
  # means the id is still taken, so it is reported and dropped, and the row
  # left without one is picked up later by `Mydia.Jobs.MetadataBackfill`,
  # which refreshes it from its own provider. Finding no owner means nothing
  # currently holds the id, so it is kept and the retry carries it as-is. A
  # third write claiming the id in the gap between this read and the retry is
  # the residual race the module accepts: the retry then fails and `write/3`
  # returns that changeset, the same outcome as any other second collision.
  defp drop_taken(attrs, type, opts) do
    Enum.reduce(@providers, attrs, fn provider, acc ->
      key = attrs_key(provider)

      case Map.get(acc, key) do
        nil ->
          acc

        id ->
          case conflicting_item(provider, id, type, opts[:exclude_id]) do
            nil ->
              acc

            other ->
              report_conflict(acc, provider, id, other, opts)
              Map.delete(acc, key)
          end
      end
    end)
  end

  defp report_conflict(attrs, provider, id, other, opts) do
    title = opts[:title] || Map.get(attrs, :title)

    Logger.warning(
      "[ExternalIds] #{provider}_id #{id} is already owned by another media item",
      media_item_id: other.id,
      existing_title: other.title,
      incoming_title: title
    )

    Events.create_event_async(%{
      category: "media",
      type: "media_item.duplicate_provider_id",
      actor_type: :system,
      actor_id: "external_ids",
      resource_type: "media_item",
      resource_id: other.id,
      severity: :warning,
      metadata: %{
        "provider" => to_string(provider),
        "provider_id" => id,
        "existing_title" => other.title,
        "incoming_title" => title
      }
    })

    attrs
  end
end
