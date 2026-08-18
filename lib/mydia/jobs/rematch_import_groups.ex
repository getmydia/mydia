defmodule Mydia.Jobs.RematchImportGroups do
  @moduledoc """
  Re-runs matching for a review selection outside the LiveView process.

  One incomplete job per library is allowed, and the import context pages the
  selected files so large libraries do not become one unbounded allocation.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, keys: [:library_path_id], states: :incomplete]

  require Logger

  alias Mydia.ImportGroups
  alias Mydia.Library.SelectionScope

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"library_path_id" => library_path_id, "selection" => args}}) do
    scope = SelectionScope.from_args(args)

    {:ok, stats} = ImportGroups.rematch_with_stats(scope)

    if stats.failures > 0 do
      Logger.warning("Import group re-match completed with file failures",
        library_path_id: library_path_id,
        processed_files: stats.files,
        failed_files: stats.failures
      )
    end

    broadcast(library_path_id)
    :ok
  end

  defp broadcast(library_path_id) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "import_groups:#{library_path_id}",
      {:import_groups_changed, library_path_id}
    )
  end
end
