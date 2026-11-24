defmodule Mydia.Jobs.SidecarCleanup do
  @moduledoc """
  Background job that moves the given orphaned sidecars of a library path to
  the trash (`Mydia.Library.SidecarCleanup.run/2`, which re-checks each path).

  Broadcasts `:sidecar_cleanup_started` and `:sidecar_cleanup_completed` on
  the `"library_scanner"` topic. Completion is broadcast on failure too, with
  an `:error` reason, so a waiting UI never hangs.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 1,
    unique: [
      period: :infinity,
      keys: [:library_path_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Mydia.Library.SidecarCleanup
  alias Mydia.Settings

  defmodule Args do
    @moduledoc false
    defstruct [:library_path_id, paths: []]

    @type t :: %__MODULE__{library_path_id: String.t() | nil, paths: [String.t()]}

    def parse(%{"library_path_id" => library_path_id} = raw) do
      %__MODULE__{library_path_id: library_path_id, paths: Map.get(raw, "paths") || []}
    end
  end

  @pubsub Mydia.PubSub
  @topic "library_scanner"

  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) do
    %Args{library_path_id: library_path_id, paths: paths} = Args.parse(raw_args)

    Logger.info("Starting sidecar cleanup job", library_path_id: library_path_id)
    broadcast(:sidecar_cleanup_started, %{library_path_id: library_path_id})

    with {:ok, library_path} <- fetch_library_path(library_path_id),
         {:ok, counts} <- SidecarCleanup.run(library_path, paths) do
      Logger.info("Sidecar cleanup completed", Map.to_list(counts))
      broadcast(:sidecar_cleanup_completed, Map.put(counts, :library_path_id, library_path_id))
      :ok
    else
      {:error, reason} ->
        Logger.warning("Sidecar cleanup failed",
          library_path_id: library_path_id,
          reason: inspect(reason)
        )

        broadcast(:sidecar_cleanup_completed, %{
          library_path_id: library_path_id,
          moved: 0,
          kept: 0,
          pruned_dirs: 0,
          error: reason
        })

        {:error, reason}
    end
  end

  @doc "Enqueues a sidecar cleanup job for the given absolute paths of the library path."
  @spec enqueue(String.t(), [String.t()]) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(library_path_id, paths) when is_list(paths) do
    %{library_path_id: library_path_id, paths: paths}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  # A deleted library path is unavailable, not a crash, so the UI hears back.
  defp fetch_library_path(id) do
    {:ok, Settings.get_library_path!(id)}
  rescue
    Ecto.NoResultsError -> {:error, :library_unavailable}
  end

  defp broadcast(event, payload), do: Phoenix.PubSub.broadcast(@pubsub, @topic, {event, payload})
end
