defmodule Mydia.Media.Categorization do
  @moduledoc """
  Owns category overrides, reclassification, and auto-search partitioning for media items.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Media.{CategoryClassifier, Episode, ItemWrites, MediaItem}

  @doc """
  Updates the category of a media item.

  ## Options
    - `:override` - If true, sets `category_override` flag to prevent auto-reclassification (default: false)
    - `:reason` - Description recorded in history (e.g., "Category updated")
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)

  Refused with `{:error, :restricted}` when the item is outside what the scope
  may write, the same rule `update_media_item/4` applies.

  ## Examples

      iex> update_category(scope, media_item, :anime_movie)
      {:ok, %MediaItem{}}

      iex> update_category(scope, media_item, :anime_movie, override: true)
      {:ok, %MediaItem{category: "anime_movie", category_override: true}}
  """
  @spec update_category(Scope.t(), MediaItem.t(), atom() | String.t(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t() | :restricted}
  def update_category(%Scope{} = scope, %MediaItem{} = media_item, category, opts \\ []) do
    with :ok <- ItemWrites.authorize_write(scope, ItemWrites.merged_write_attrs(media_item, %{})) do
      override = Keyword.get(opts, :override, false)
      audit_opts = Keyword.take(opts, [:reason, :actor_type, :actor_id])

      changeset = MediaItem.category_changeset(media_item, category, override: override)
      ItemWrites.persist_and_audit_media_item(changeset, media_item, audit_opts)
    end
  end

  @doc """
  Clears the category override flag, allowing auto-reclassification on metadata refresh.

  ## Examples

      iex> clear_category_override(media_item)
      {:ok, %MediaItem{category_override: false}}
  """
  @spec clear_category_override(MediaItem.t()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t()}
  def clear_category_override(%MediaItem{} = media_item) do
    media_item
    |> MediaItem.clear_category_override_changeset()
    |> Repo.update()
  end

  @doc """
  Re-classifies a media item based on its current metadata.

  If `category_override` is true, the category is not changed unless `force: true` is passed.

  ## Options
    - `:force` - If true, ignores the override flag and re-classifies anyway (default: false)

  ## Examples

      iex> reclassify_media_item(media_item)
      {:ok, %MediaItem{}}
  """
  @spec reclassify_media_item(MediaItem.t(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t()}
  def reclassify_media_item(%MediaItem{} = media_item, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if media_item.category_override && !force do
      {:ok, media_item}
    else
      category = CategoryClassifier.classify(media_item)

      media_item
      |> MediaItem.category_changeset(category)
      |> Repo.update()
    end
  end

  @doc """
  Re-classifies all media items that don't have a category override.

  Useful for backfilling categories on existing media items.

  Returns `{:ok, count}` where count is the number of updated items.
  """
  @spec reclassify_all_media_items() :: {:ok, non_neg_integer()}
  def reclassify_all_media_items do
    MediaItem
    |> where([m], m.category_override == false or is_nil(m.category_override))
    |> Repo.all()
    |> Enum.reduce(0, fn media_item, count ->
      category = CategoryClassifier.classify(media_item)

      case update_category(Scope.system(), media_item, category) do
        {:ok, _} -> count + 1
        {:error, _} -> count
      end
    end)
    |> then(&{:ok, &1})
  end

  @doc """
  Re-classifies multiple media items by their IDs.

  Returns a summary map with counts and details of what changed.

  ## Options
    - `:force` - If true, ignores category_override flags (default: false)

  ## Returns

      {:ok, %{
        total: 10,
        updated: 5,
        skipped: 3,
        unchanged: 2,
        details: [%{id: "...", old_category: "movie", new_category: "anime_movie", changed: true}, ...]
      }}
  """
  @spec reclassify_media_items([binary()], keyword()) :: {:ok, map()}
  def reclassify_media_items(ids, opts \\ []) when is_list(ids) do
    force = Keyword.get(opts, :force, false)

    media_items =
      MediaItem
      |> where([m], m.id in ^ids)
      |> Repo.all()

    results =
      Enum.map(media_items, fn media_item ->
        old_category = media_item.category
        new_category = CategoryClassifier.classify(media_item)

        cond do
          media_item.category_override && !force ->
            %{
              id: media_item.id,
              title: media_item.title,
              old_category: old_category,
              new_category: old_category,
              changed: false,
              skipped: true,
              reason: "category_override"
            }

          to_string(old_category) == to_string(new_category) ->
            %{
              id: media_item.id,
              title: media_item.title,
              old_category: old_category,
              new_category: to_string(new_category),
              changed: false,
              skipped: false,
              reason: nil
            }

          true ->
            case update_category(Scope.system(), media_item, new_category) do
              {:ok, _updated} ->
                %{
                  id: media_item.id,
                  title: media_item.title,
                  old_category: old_category,
                  new_category: to_string(new_category),
                  changed: true,
                  skipped: false,
                  reason: nil
                }

              {:error, _} ->
                %{
                  id: media_item.id,
                  title: media_item.title,
                  old_category: old_category,
                  new_category: old_category,
                  changed: false,
                  skipped: true,
                  reason: "update_failed"
                }
            end
        end
      end)

    summary = %{
      total: length(results),
      updated: Enum.count(results, & &1.changed),
      skipped: Enum.count(results, & &1.skipped),
      unchanged: Enum.count(results, &(!&1.changed && !&1.skipped)),
      details: results
    }

    {:ok, summary}
  end

  @doc """
  Partitions selected media item ids into those needing an automatic release
  search and a count of those that do not need one.

  A movie needs a search when it has no untrashed media file and no occupying
  download (see `Mydia.Downloads.Download.occupying/1`). Monitored status is not
  part of the movie rule: `Mydia.Jobs.MovieSearch` in `"specific"` mode does not
  check it either, so an unmonitored movie is still searchable on request.

  A TV show needs a search when at least one of its episodes is monitored (show
  and episode), has aired, has no untrashed media file, and has no occupying
  download, excluding S00 specials unless `:monitor_special_episodes` is set.
  That is the same set `Mydia.Jobs.TVShowSearch` searches in `"show"` mode, so
  the caller's queued/skipped counts match what the job will actually do.

  Ids that no longer exist are counted in neither the returned list nor the
  skipped count, so a stale selection still reports truthful numbers.

  Returns `{items_needing_search, skipped_count}`.
  """
  @spec partition_for_auto_search([binary()]) :: {[MediaItem.t()], non_neg_integer()}
  def partition_for_auto_search([]), do: {[], 0}

  def partition_for_auto_search(ids) when is_list(ids) do
    items = movies_needing_search(ids) ++ shows_needing_search(ids)

    existing_count =
      MediaItem
      |> where([m], m.id in ^ids)
      |> Repo.aggregate(:count)

    {items, existing_count - length(items)}
  end

  defp movies_needing_search(ids) do
    MediaItem
    |> where([m], m.id in ^ids and m.type == "movie")
    |> where([m], m.id not in subquery(occupying_download_media_item_ids()))
    |> join(:left, [m], mf in Mydia.Library.MediaFile,
      on: mf.media_item_id == m.id and is_nil(mf.trashed_at) and is_nil(mf.extra_kind)
    )
    |> group_by([m], m.id)
    |> having([_m, mf], count(mf.id) == 0)
    |> Repo.all()
  end

  defp occupying_download_media_item_ids do
    Mydia.Downloads.Download.occupying()
    |> where([d], not is_nil(d.media_item_id))
    |> select([d], d.media_item_id)
    |> distinct(true)
  end

  defp shows_needing_search(ids) do
    show_ids =
      Episode
      |> join(:inner, [e], m in assoc(e, :media_item))
      |> where([e, m], e.media_item_id in ^ids and m.type == "tv_show")
      |> where([e, m], e.monitored == true and m.monitored == true)
      |> where([e], e.air_date <= ^Date.utc_today())
      |> exclude_special_episodes()
      |> where([e], e.id not in subquery(occupying_download_episode_ids()))
      |> join(:left, [e], mf in Mydia.Library.MediaFile,
        on: mf.episode_id == e.id and is_nil(mf.trashed_at) and is_nil(mf.extra_kind)
      )
      |> group_by([e], e.id)
      |> having([_e, _m, mf], count(mf.id) == 0)
      |> select([e], e.media_item_id)
      |> distinct(true)
      |> Repo.all()

    MediaItem
    |> where([m], m.id in ^show_ids)
    |> Repo.all()
  end

  defp exclude_special_episodes(query) do
    if monitor_special_episodes?() do
      query
    else
      where(query, [e], e.season_number != 0)
    end
  end

  defp monitor_special_episodes? do
    :mydia
    |> Application.get_env(:episode_monitor, [])
    |> Keyword.get(:monitor_special_episodes, false)
  end

  defp occupying_download_episode_ids do
    Mydia.Downloads.Download.occupying()
    |> where([d], not is_nil(d.episode_id))
    |> select([d], d.episode_id)
    |> distinct(true)
  end
end
