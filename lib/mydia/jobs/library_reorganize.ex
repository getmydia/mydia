defmodule Mydia.Jobs.LibraryReorganize do
  @moduledoc """
  Background job for reorganizing files in a library based on category paths.

  This job moves existing media files to their category-appropriate paths
  when auto_organize is enabled on a library path.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 1

  require Logger
  alias Mydia.Settings
  alias Mydia.Library.FileOrganizer

  defmodule Args do
    @moduledoc false
    defstruct [:library_path_id]

    @type t :: %__MODULE__{library_path_id: String.t() | nil}

    def parse(%{"library_path_id" => library_path_id}) do
      %__MODULE__{library_path_id: library_path_id}
    end
  end

  @pubsub Mydia.PubSub
  @topic "library_scanner"

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) do
    args = Args.parse(raw_args)
    library_path_id = args.library_path_id
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Starting library reorganization job",
      library_path_id: library_path_id
    )

    broadcast_started(library_path_id)

    library_path = Settings.get_library_path!(library_path_id)

    case FileOrganizer.reorganize_library(library_path) do
      {:ok, summary} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Logger.info("Library reorganization completed",
          library_path_id: library_path_id,
          total: summary.total,
          moved: summary.moved,
          skipped: summary.skipped,
          errors: summary.errors,
          duration_ms: duration
        )

        broadcast_completed(library_path_id, summary)
        :ok

      {:error, %Mydia.Storage.Error{message: message}} ->
        # Retrying cannot make an S3 library writable.
        Logger.warning("Library reorganization refused",
          library_path_id: library_path_id,
          reason: message
        )

        {:cancel, message}
    end
  end

  @doc """
  Enqueues a library reorganization job.
  """
  def enqueue(library_path_id) do
    %{library_path_id: library_path_id}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  defp broadcast_started(library_path_id) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {
      :library_reorganize_started,
      %{library_path_id: library_path_id}
    })
  end

  defp broadcast_completed(library_path_id, summary) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {
      :library_reorganize_completed,
      %{
        library_path_id: library_path_id,
        total: summary.total,
        moved: summary.moved,
        skipped: summary.skipped,
        errors: summary.errors
      }
    })
  end
end
