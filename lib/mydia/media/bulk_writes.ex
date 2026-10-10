defmodule Mydia.Media.BulkWrites do
  @moduledoc """
  Owns updating many media items at once: monitored flags and batch attribute edits.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Media.MediaItem
  alias Mydia.Events

  @doc """
  Updates the monitored status for multiple media items.

  Returns `{:ok, count}` where count is the number of updated items,
  or `{:error, reason}` if the transaction fails.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  @spec update_media_items_monitored(Scope.t(), [binary()], boolean(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_media_items_monitored(%Scope{} = _scope, ids, monitored, opts \\ [])
      when is_list(ids) do
    Repo.transaction(fn ->
      # Fetch media items before update to track events
      media_items =
        MediaItem
        |> where([m], m.id in ^ids)
        |> Repo.all()

      # Perform the update
      {count, _} =
        MediaItem
        |> where([m], m.id in ^ids)
        |> Repo.update_all(set: [monitored: monitored, updated_at: DateTime.utc_now()])

      # Track events for each media item
      actor_type = Keyword.get(opts, :actor_type, :system)
      actor_id = Keyword.get(opts, :actor_id, "media_context")

      Enum.each(media_items, fn media_item ->
        Events.media_item_monitoring_changed(media_item, monitored, actor_type, actor_id)
      end)

      count
    end)
  end

  @doc """
  Updates multiple media items with the given attributes in a transaction.

  Only updates non-nil attributes. Returns `{:ok, count}` on success
  where count is the number of updated items, or `{:error, :not_found}` if
  `attrs` references a quality profile or library path that does not exist.

  When `attrs` sets `:monitored`, this records a monitoring decision for every
  affected item, exactly like `update_media_items_monitored/3` does. Without
  that, an operator re-enabling monitoring here instead of through the
  dedicated toggle would leave no decision on record, and
  `Mydia.Jobs.MonitoringRepair` would read the item's last recorded decision
  as the earlier disable and undo the re-enable on the next boot
  (getmydia/mydia#653). A batch that does not touch `:monitored` emits nothing.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  @spec update_media_items_batch(Scope.t(), [binary()], map(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :not_found | term()}
  def update_media_items_batch(%Scope{} = _scope, ids, attrs, opts \\ [])
      when is_list(ids) and is_map(attrs) do
    if referenced_foreign_keys_exist?(attrs) do
      do_update_media_items_batch(ids, attrs, opts)
    else
      {:error, :not_found}
    end
  end

  # Repo.update_all/3 takes no changeset, so Mydia.Repo.ForeignKeyGuard cannot
  # turn a foreign key violation below into a changeset error: it raises on
  # both SQLite and PostgreSQL, unlike the changeset-backed writes elsewhere
  # in this branch. Check the referenced rows up front instead.
  defp referenced_foreign_keys_exist?(attrs) do
    reference_exists?(Mydia.Settings.QualityProfile, attrs[:quality_profile_id]) and
      reference_exists?(Mydia.Settings.LibraryPath, attrs[:library_path_id])
  end

  defp reference_exists?(_schema, nil), do: true

  defp reference_exists?(schema, id) do
    Repo.exists?(from(r in schema, where: r.id == ^id))
  rescue
    # PostgreSQL raises while binding a non-UUID-shaped id. It certainly does
    # not exist.
    Ecto.Query.CastError -> false
  end

  defp do_update_media_items_batch(ids, attrs, opts) do
    Repo.transaction(fn ->
      # Build the update list, only including non-nil values
      updates =
        attrs
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Enum.into(%{})
        |> Map.put(:updated_at, DateTime.utc_now())

      if map_size(updates) > 1 do
        # More than just updated_at

        # Fetch media items before the update, but only when the batch
        # touches :monitored: a quality-profile-only batch has nothing to
        # record and should pay no extra query.
        media_items =
          if Map.has_key?(updates, :monitored) do
            MediaItem
            |> where([m], m.id in ^ids)
            |> Repo.all()
          else
            []
          end

        {count, _} =
          MediaItem
          |> where([m], m.id in ^ids)
          |> Repo.update_all(set: Map.to_list(updates))

        unless media_items == [] do
          monitored = normalize_monitored(Map.fetch!(updates, :monitored))
          actor_type = Keyword.get(opts, :actor_type, :system)
          actor_id = Keyword.get(opts, :actor_id, "media_context")

          Enum.each(media_items, fn media_item ->
            Events.media_item_monitoring_changed(media_item, monitored, actor_type, actor_id)
          end)
        end

        count
      else
        0
      end
    end)
  end

  # The batch edit form in the LiveView posts "true"/"false" strings; direct
  # callers (tests, other contexts) pass real booleans. Repo.update_all casts
  # either shape fine for the write itself, but the monitoring_changed event's
  # metadata must carry an actual boolean, not the literal string "true".
  defp normalize_monitored(true), do: true
  defp normalize_monitored(false), do: false
  defp normalize_monitored("true"), do: true
  defp normalize_monitored("false"), do: false
end
