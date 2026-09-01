defmodule Mydia.Jobs.ApplyImportCandidates do
  @moduledoc """
  Promotes the import candidates a user queued for accept.

  Runs on `:default` rather than `:imports`, which has concurrency 1 and is held
  for the duration of a library scan. An accept queued behind a multi-hour run
  would look like the button did nothing.

  The job carries no selection. `Mydia.ImportCandidates.drain_accepted/2`
  discovers its work from the `queued_op` column, so this is safe to enqueue
  more than once for one library and safe to retry: a restart resumes from
  whatever is still marked.

  `unique` deliberately omits `:executing`, where the pre-split
  `Jobs.ApplyImportGroups` used `:incomplete`. A click landing while a drain is
  already running must enqueue a fresh job rather than be swallowed by the
  uniqueness guard, otherwise rows marked during the final page are stranded
  with nothing left to pick them up. `Jobs.MediaImport` documents the same
  tradeoff.

  A library with candidates still queued at the end is reported to Oban as a
  failure so `max_attempts` retries it. Terminal refusals do not reach that
  path; the drain clears their markers and records `queue_error` instead.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, keys: [:library_path_id], states: [:available, :scheduled, :retryable]]

  alias Mydia.ImportCandidates

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"library_path_id" => library_path_id}}) do
    case ImportCandidates.drain_accepted(library_path_id, allow_episode_creation: true) do
      {:ok, %{remaining: 0}} -> :ok
      {:ok, %{remaining: n}} -> {:error, "#{n} queued candidate(s) did not import"}
    end
  end
end
