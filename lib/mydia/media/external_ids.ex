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

  ## Options

  The same `:type` (required), `:exclude_id` and `:title` as `put_free_ids/3`.
  """
  @spec write(map(), keyword(), (map() -> {:ok, term()} | {:error, Ecto.Changeset.t()})) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()}
  def write(attrs, opts, fun) when is_function(fun, 1) do
    type = fetch_type!(opts)

    case fun.(attrs) do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if provider_id_conflict?(changeset) do
          fun.(drop_taken(attrs, type, opts))
        else
          error
        end

      other ->
        other
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
  # The owner found here may have vanished by the time this runs, or may not
  # be who the original write collided with -- either is fine, since the id
  # cannot be proven free and dropping it is always safe.
  # `Mydia.Jobs.MetadataBackfill` refreshes the row from its own provider
  # later.
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
