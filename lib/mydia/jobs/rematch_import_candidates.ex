defmodule Mydia.Jobs.RematchImportCandidates do
  @moduledoc """
  Re-runs metadata matching for the candidates a user queued for re-match.

  The pre-split `Jobs.RematchImportGroups` carried the selection in its args and
  rebuilt it with `SelectionScope.from_args/1`. This one does not: the intent
  lives on the row, so the snapshot is taken when the user clicks rather than
  re-derived from band and search predicates that may match different groups by
  the time the job runs.

  Shares `Jobs.ApplyImportCandidates`'s queue and uniqueness reasoning
  (including where the narrowed `unique` `states:` list actually lives). The
  two workers never contend for a row, because a candidate carries at most one
  `queued_op` and each worker filters on its own value.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, keys: [:library_path_id]]

  require Logger

  alias Mydia.ImportCandidates

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"library_path_id" => library_path_id}}) do
    {:ok, stats} = ImportCandidates.drain_rematch(library_path_id)

    if stats.failures > 0 do
      Logger.warning("Import candidate re-match completed with file failures",
        library_path_id: library_path_id,
        processed_files: stats.files,
        failed_files: stats.failures
      )
    end

    :ok
  end
end
