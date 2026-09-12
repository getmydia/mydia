defmodule MydiaWeb.LibrarySchema.Resolvers.Search do
  @moduledoc """
  Resolves the search mutations by enqueuing the jobs the media page's own
  buttons enqueue, with the arguments each worker documents.

  `queued` is true whenever the insert succeeds. The search workers are unique
  for 60 seconds on their arguments, so a repeat inside that window is merged by
  Oban and still reports true.
  """

  alias Mydia.Jobs.TVShowSearch
  alias Mydia.Search
  alias MydiaWeb.LibrarySchema.Loaders
  alias MydiaWeb.LibrarySchema.UserError

  @spec search_media_item(any(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, String.t()}
  def search_media_item(_parent, %{id: id}, _resolution) do
    with {:ok, item} <- Loaders.item(id, ["id"]),
         {:ok, _count} <- Search.queue_auto_searches([item]) do
      # Any successful insert (including a repeat merged by Oban's uniqueness
      # constraint) should report queued: true. queue_auto_searches returns
      # count: 0 when the job was deduped (conflict?: true), but the job is
      # still merged into the queue.
      {:ok, %{queued: true, user_errors: []}}
    else
      {:error, %UserError{} = error} -> {:ok, not_queued(error)}
      {:error, _reason} -> {:error, "Could not queue the search"}
    end
  end

  @spec search_season(any(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, String.t()}
  def search_season(_parent, %{media_item_id: id, season: season}, _resolution) do
    with {:ok, item} <- Loaders.item(id, ["mediaItemId"]),
         :ok <- Loaders.require_show(item, ["mediaItemId"]),
         {:ok, season} <- validate_season(season) do
      insert(%{mode: "season", media_item_id: item.id, season_number: season})
    else
      {:error, %UserError{} = error} -> {:ok, not_queued(error)}
    end
  end

  @spec search_episode(any(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, String.t()}
  def search_episode(_parent, %{id: id}, _resolution) do
    case Loaders.episode(id, ["id"]) do
      {:ok, episode} -> insert(%{mode: "specific", episode_id: episode.id})
      {:error, %UserError{} = error} -> {:ok, not_queued(error)}
    end
  end

  # Season 0 is specials, so it stays valid; only negative seasons are
  # rejected. TVShowSearch's "season" mode otherwise accepts a negative
  # season_number, matches no episodes (season_number is never negative in
  # the DB), and completes having searched nothing - see load_episodes_for_season/2
  # and the "season" perform/1 clause in lib/mydia/jobs/tv_show_search.ex.
  defp validate_season(season) when is_integer(season) and season >= 0, do: {:ok, season}

  defp validate_season(_season),
    do: {:error, UserError.new(:invalid_input, "Must be 0 or greater", ["season"])}

  defp insert(args) do
    case args |> TVShowSearch.new() |> Oban.insert() do
      {:ok, _job} -> {:ok, %{queued: true, user_errors: []}}
      {:error, _reason} -> {:error, "Could not queue the search"}
    end
  end

  defp not_queued(error), do: %{queued: false, user_errors: [error]}
end
