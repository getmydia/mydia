defmodule Mydia.Jobs.DeleteImportCandidates do
  @moduledoc """
  Permanently deletes the files a user queued for delete on the Import page.

  The intent lives on the row (`queued_op: "delete"`), as it does for
  `Jobs.ApplyImportCandidates` and `Jobs.RematchImportCandidates`, so this job
  carries only the library path and discovers its own work. It shares their
  queue and uniqueness reasoning, including where the narrowed `unique`
  `states:` list lives (`Mydia.ImportCandidates`' private `enqueue/2`). The
  three never contend for a row: a candidate carries at most one `queued_op`
  and each worker drains only its own value.

  A file that could not be removed is not a job failure.
  `Mydia.ImportCandidates.drain_delete/2` writes the reason onto the candidate
  and takes it out of the queue, so the operator sees it on the Import page
  instead of Oban retrying an unlink that will fail the same way.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, keys: [:library_path_id]]

  require Logger

  alias Mydia.ImportCandidates

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"library_path_id" => library_path_id}}) do
    {:ok, stats} = ImportCandidates.drain_delete(library_path_id)

    if stats.failed > 0 do
      Logger.warning("Some queued import files could not be deleted from disk",
        library_path_id: library_path_id,
        deleted: stats.deleted,
        failed: stats.failed,
        skipped: stats.skipped
      )
    end

    :ok
  end
end
