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
    batch_size = Map.get(args, "batch_size", @batch_size)

    config =
      Application.get_env(:mydia, :content_rating_fetch_config) || Metadata.default_relay_config()

    %{filled: filled, errors: errors} =
      walk(nil, %{config: config, delay: delay, batch_size: batch_size}, %{filled: 0, errors: 0})

    Logger.info("ContentRatingFetch filled #{filled} media items (#{errors} relay errors)")

    # A relay outage must not retire this unique job: fail so Oban retries.
    # Rows already filled are skipped on the retry by the batch query.
    if errors > 0, do: {:error, {:relay_errors, errors}}, else: :ok
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 300 * attempt

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

  defp walk(after_id, opts, acc) do
    case batch(after_id, opts.batch_size) do
      [] ->
        acc

      items ->
        acc =
          items
          |> Enum.reject(&rating_stored?/1)
          |> Enum.reduce(acc, fn item, acc ->
            case fill(item, opts.config, opts.delay) do
              :filled -> %{acc | filled: acc.filled + 1}
              :unrated -> acc
              :error -> %{acc | errors: acc.errors + 1}
            end
          end)

        walk(List.last(items).id, opts, acc)
    end
  end

  defp batch(after_id, batch_size) do
    MediaItem
    |> where(
      [m],
      is_nil(m.content_rating_age) and not is_nil(m.tmdb_id) and not is_nil(m.metadata)
    )
    |> where([m], m.type in ["movie", "tv_show"])
    |> then(fn q -> if after_id, do: where(q, [m], m.id > ^after_id), else: q end)
    |> order_by([m], asc: m.id)
    |> limit(^batch_size)
    |> Repo.all()
  end

  defp rating_stored?(%MediaItem{metadata: %{content_rating: r}}) when is_binary(r) and r != "",
    do: true

  defp rating_stored?(_item), do: false

  # :unrated means TMDB answered without a certification, which is final until
  # a metadata refresh; :error is a transport or HTTP failure worth retrying.
  defp fill(%MediaItem{} = item, config, delay) do
    if delay > 0, do: Process.sleep(delay)
    media_type = if item.type == "tv_show", do: :tv_show, else: :movie

    case Metadata.fetch_by_ref(config, {:tmdb, item.tmdb_id},
           media_type: media_type,
           append_to_response: []
         ) do
      {:ok, %{content_rating: rating}} when is_binary(rating) and rating != "" ->
        store_rating(item, rating)

      {:ok, _no_certification} ->
        :unrated

      {:error, reason} ->
        Logger.warning("ContentRatingFetch: lookup failed for #{item.id}: #{inspect(reason)}")
        :error
    end
  end

  defp store_rating(item, rating) do
    item
    |> MediaItem.changeset(%{metadata: %{item.metadata | content_rating: rating}})
    |> Repo.update()
    |> case do
      {:ok, _} -> :filled
      {:error, _} -> :unrated
    end
  end
end
