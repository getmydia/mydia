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
         {:ok, count} <- Search.queue_auto_searches([item]) do
      {:ok, %{queued: count > 0, user_errors: []}}
    else
      {:error, %UserError{} = error} -> {:ok, not_queued(error)}
      {:error, _reason} -> {:error, "Could not queue the search"}
    end
  end

  @spec search_season(any(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, String.t()}
  def search_season(_parent, %{media_item_id: id, season: season}, _resolution) do
    with {:ok, item} <- Loaders.item(id, ["mediaItemId"]),
         :ok <- Loaders.require_show(item, ["mediaItemId"]) do
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

  defp insert(args) do
    case args |> TVShowSearch.new() |> Oban.insert() do
      {:ok, _job} -> {:ok, %{queued: true, user_errors: []}}
      {:error, _reason} -> {:error, "Could not queue the search"}
    end
  end

  defp not_queued(error), do: %{queued: false, user_errors: [error]}
end
