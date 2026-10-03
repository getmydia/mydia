defmodule Mydia.Jobs.ContentRatingFetch do
  @moduledoc """
  Fetches a certification for library items that have none stored.

  Titles added through Discover, requests or import lists were saved without
  one until #1000, and most TVDB-sourced shows never get one from TVDB. Under
  an age limit an unrated title is hidden, so these rows were invisible to
  every age-limited account. `ContentRatingAgeBackfill` cannot help: it only
  re-derives the age from a rating already stored.

  Runs once per install (unique forever on `version`), at boot. Bump
  `@version` to run it again after a change to how ratings are sourced.
  Rows TMDB has no certification for keep a NULL age; the weekly metadata
  refresh and manual refreshes are their only further chance.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:version], states: :all]

  import Ecto.Query

  require Logger

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata
  alias Mydia.Repo

  @version 1
  @batch_size 100
  @default_delay_ms 250

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    delay = Map.get(args, "delay_ms", @default_delay_ms)

    config =
      Application.get_env(:mydia, :content_rating_fetch_config) || Metadata.default_relay_config()

    filled = walk(nil, config, delay, 0)
    Logger.info("ContentRatingFetch filled #{filled} media items")
    :ok
  end

  @doc """
  Enqueues the one-time run. Called at boot; never raises.
  """
  @spec enqueue_once() :: :ok
  def enqueue_once do
    %{"version" => @version} |> new() |> Oban.insert()
    :ok
  rescue
    error ->
      Logger.warning("ContentRatingFetch: failed to enqueue on boot", error: inspect(error))
      :ok
  end

  defp walk(after_id, config, delay, filled) do
    case batch(after_id) do
      [] ->
        filled

      items ->
        count =
          items
          |> Enum.reject(&rating_stored?/1)
          |> Enum.count(&fill(&1, config, delay))

        walk(List.last(items).id, config, delay, filled + count)
    end
  end

  defp batch(after_id) do
    MediaItem
    |> where(
      [m],
      is_nil(m.content_rating_age) and not is_nil(m.tmdb_id) and not is_nil(m.metadata)
    )
    |> where([m], m.type in ["movie", "tv_show"])
    |> then(fn q -> if after_id, do: where(q, [m], m.id > ^after_id), else: q end)
    |> order_by([m], asc: m.id)
    |> limit(@batch_size)
    |> Repo.all()
  end

  defp rating_stored?(%MediaItem{metadata: %{content_rating: r}}) when is_binary(r) and r != "",
    do: true

  defp rating_stored?(_item), do: false

  defp fill(%MediaItem{} = item, config, delay) do
    if delay > 0, do: Process.sleep(delay)
    media_type = if item.type == "tv_show", do: :tv_show, else: :movie

    with {:ok, %{content_rating: rating}} when is_binary(rating) <-
           Metadata.fetch_by_ref(config, {:tmdb, item.tmdb_id},
             media_type: media_type,
             append_to_response: []
           ),
         {:ok, _} <-
           item
           |> MediaItem.changeset(%{metadata: %{item.metadata | content_rating: rating}})
           |> Repo.update() do
      true
    else
      _ -> false
    end
  end
end
