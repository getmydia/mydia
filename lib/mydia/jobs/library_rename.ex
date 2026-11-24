defmodule Mydia.Jobs.LibraryRename do
  @moduledoc """
  Background job that renames every file of a library path to the naming
  template, regardless of the library's `auto_rename` setting.

  Broadcasts on the `"library_scanner"` topic: `:library_rename_started`,
  `:library_rename_progress` (at most once per media item) and
  `:library_rename_completed`.
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

  alias Mydia.Library.BulkRename
  alias Mydia.Settings

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

  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) do
    %Args{library_path_id: library_path_id} = Args.parse(raw_args)
    library_path = Settings.get_library_path!(library_path_id)

    Logger.info("Starting library rename job", library_path_id: library_path_id)
    broadcast(:library_rename_started, %{library_path_id: library_path_id})

    on_progress = fn {done, total} ->
      broadcast(:library_rename_progress, %{
        library_path_id: library_path_id,
        done: done,
        total: total
      })
    end

    case BulkRename.run(library_path, on_progress: on_progress) do
      {:ok, counts} ->
        Logger.info("Library rename completed", Map.to_list(counts))
        broadcast(:library_rename_completed, Map.put(counts, :library_path_id, library_path_id))
        :ok

      {:error, reason} ->
        Logger.warning("Library rename failed",
          library_path_id: library_path_id,
          reason: inspect(reason)
        )

        broadcast(
          :library_rename_completed,
          %{
            library_path_id: library_path_id,
            renamed: 0,
            unchanged: 0,
            conflicts: 0,
            errors: 0,
            error: reason
          }
        )

        {:error, reason}
    end
  end

  @doc "Enqueues a library rename job for the library path."
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(library_path_id) do
    %{library_path_id: library_path_id}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  defp broadcast(event, payload), do: Phoenix.PubSub.broadcast(@pubsub, @topic, {event, payload})
end
