defmodule Mydia.Library.ScanTriggers do
  @moduledoc """
  Owns enqueueing manual and full library scan and metadata refresh jobs.
  """

  @doc """
  Triggers a manual library scan for a specific library path.

  Returns an Oban job that will perform the scan.
  """
  @spec trigger_library_scan(binary()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_library_scan(library_path_id) do
    %{library_path_id: library_path_id}
    |> Mydia.Jobs.LibraryScanner.new()
    |> Mydia.Jobs.insert()
  end

  @doc """
  Triggers a library scan for all monitored library paths.

  ## Options

    - `:schedule_in` - Seconds to wait before the scan runs. Omitted by manual
      triggers, which should start immediately. Automatic callers pass
      `Mydia.Jobs.LibraryScanner.jitter_seconds/0` so that instances restarting
      on the same new image do not hit the metadata relay at once.

  Returns an Oban job that will perform the scan.
  """
  @spec trigger_full_library_scan(keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_full_library_scan(opts \\ []) do
    %{}
    |> Mydia.Jobs.LibraryScanner.new(Keyword.take(opts, [:schedule_in]))
    |> Mydia.Jobs.insert()
  end

  @doc """
  Triggers a metadata refresh for a specific media item.

  ## Options
    - `:fetch_episodes` - For TV shows, whether to refresh episodes (default: true)

  Returns an Oban job that will perform the refresh.
  """
  @spec trigger_metadata_refresh(binary(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_metadata_refresh(media_item_id, opts \\ []) do
    fetch_episodes = Keyword.get(opts, :fetch_episodes, true)

    %{media_item_id: media_item_id, fetch_episodes: fetch_episodes}
    |> Mydia.Jobs.MetadataRefresh.new()
    |> Oban.insert()
  end

  @doc """
  Triggers a metadata refresh for all monitored media items.

  Returns an Oban job that will perform the refresh.
  """
  @spec trigger_full_metadata_refresh() :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_full_metadata_refresh do
    %{refresh_all: true}
    |> Mydia.Jobs.MetadataRefresh.new()
    |> Oban.insert()
  end
end
