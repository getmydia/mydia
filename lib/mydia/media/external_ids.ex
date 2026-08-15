defmodule Mydia.Media.ExternalIds do
  @moduledoc """
  Decides which provider ids an attrs map may safely take.

  `media_items` carries a unique index on `tmdb_id` and another on `tvdb_id`,
  so writing a cross-referenced id blindly turns an ordinary metadata refresh
  into a constraint error. Every path that learns a second provider id for an
  item goes through `put_free_ids/3`, which adds only the ids no other row
  already owns and reports the ones it skipped.

  A skipped id means the library holds two rows for one title. That is worth
  telling the operator about, so it becomes a warning event on the activity
  timeline rather than a log line nobody reads. Rows are never merged or
  deleted here; which one to keep is the operator's call.
  """

  require Logger

  alias Mydia.Events
  alias Mydia.Media

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

    * `:exclude_id` - id of the media item being updated. A row writing its own
      id back is not a conflict.
    * `:title` - title used in the warning when a conflict is reported.
      Defaults to `attrs[:title]`.
  """
  @spec put_free_ids(map(), t() | nil, keyword()) :: map()
  def put_free_ids(attrs, external_ids, opts \\ [])

  def put_free_ids(attrs, nil, _opts), do: attrs

  def put_free_ids(attrs, external_ids, opts) when is_map(external_ids) do
    Enum.reduce(@providers, attrs, fn provider, acc ->
      put_free_id(acc, provider, Map.get(external_ids, provider), opts)
    end)
  end

  defp put_free_id(attrs, _provider, nil, _opts), do: attrs

  defp put_free_id(attrs, provider, id, opts) do
    key = attrs_key(provider)

    if is_nil(Map.get(attrs, key)) do
      case conflicting_item(provider, id, opts[:exclude_id]) do
        nil -> Map.put(attrs, key, id)
        other -> report_conflict(attrs, provider, id, other, opts)
      end
    else
      attrs
    end
  end

  defp attrs_key(:tmdb), do: :tmdb_id
  defp attrs_key(:tvdb), do: :tvdb_id

  defp conflicting_item(provider, id, exclude_id) do
    case lookup(provider, id) do
      nil -> nil
      %{id: ^exclude_id} -> nil
      item -> item
    end
  end

  defp lookup(:tmdb, id), do: Media.get_media_item_by_tmdb(id)
  defp lookup(:tvdb, id), do: Media.get_media_item_by_tvdb(id)

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
