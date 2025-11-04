defmodule Mydia.Downloads do
  @moduledoc """
  The Downloads context handles download queue management.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Downloads.Download
  alias Phoenix.PubSub

  @doc """
  Returns the list of downloads.

  ## Options
    - `:status` - Filter by status
    - `:media_item_id` - Filter by media item
    - `:episode_id` - Filter by episode
    - `:preload` - List of associations to preload
  """
  def list_downloads(opts \\ []) do
    Download
    |> apply_download_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single download.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the download does not exist.
  """
  def get_download!(id, opts \\ []) do
    Download
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates a download.
  """
  def create_download(attrs \\ %{}) do
    result =
      %Download{}
      |> Download.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, download} ->
        broadcast_download_update(download.id)
        {:ok, download}

      error ->
        error
    end
  end

  @doc """
  Updates a download.
  """
  def update_download(%Download{} = download, attrs) do
    result =
      download
      |> Download.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_download} ->
        broadcast_download_update(updated_download.id)
        {:ok, updated_download}

      error ->
        error
    end
  end

  @doc """
  Updates download progress.
  """
  def update_download_progress(%Download{} = download, progress, estimated_completion \\ nil) do
    attrs =
      if estimated_completion do
        %{progress: progress, estimated_completion: estimated_completion}
      else
        %{progress: progress}
      end

    update_download(download, attrs)
  end

  @doc """
  Marks a download as completed.
  """
  def complete_download(%Download{} = download) do
    download
    |> Download.changeset(%{status: "completed", completed_at: DateTime.utc_now(), progress: 100})
    |> Repo.update()
  end

  @doc """
  Marks a download as failed.
  """
  def fail_download(%Download{} = download, error_message) do
    download
    |> Download.changeset(%{status: "failed", error_message: error_message})
    |> Repo.update()
  end

  @doc """
  Cancels a download.
  """
  def cancel_download(%Download{} = download) do
    download
    |> Download.changeset(%{status: "cancelled"})
    |> Repo.update()
  end

  @doc """
  Deletes a download.
  """
  def delete_download(%Download{} = download) do
    Repo.delete(download)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking download changes.
  """
  def change_download(%Download{} = download, attrs \\ %{}) do
    Download.changeset(download, attrs)
  end

  @doc """
  Gets all active downloads (pending or downloading).
  """
  def list_active_downloads(opts \\ []) do
    list_downloads([status: ["pending", "downloading"]] ++ opts)
  end

  ## Private Functions

  defp apply_download_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:status, status}, query when is_list(status) ->
        where(query, [d], d.status in ^status)

      {:status, status}, query ->
        where(query, [d], d.status == ^status)

      {:media_item_id, media_item_id}, query ->
        where(query, [d], d.media_item_id == ^media_item_id)

      {:episode_id, episode_id}, query ->
        where(query, [d], d.episode_id == ^episode_id)

      _other, query ->
        query
    end)
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, []), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  @doc """
  Broadcasts a download update to all subscribed LiveViews.
  """
  def broadcast_download_update(download_id) do
    PubSub.broadcast(Mydia.PubSub, "downloads", {:download_updated, download_id})
  end
end
