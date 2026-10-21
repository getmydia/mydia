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
  tradeoff. The narrowed `states:` list lives on `ImportCandidates.Store.enqueue/2`,
  the single call site both this worker and `Jobs.RematchImportCandidates`
  share, rather than here: declaring it statically on `use Oban.Worker` trips
  Oban's compile-time `--warnings-as-errors` check for a missing incomplete
  state, the same reason `Jobs.MediaImport.Failure.schedule_snooze_retry/3` overrides
  it at its own call site instead of in its module attributes.

  A library with candidates still queued at the end is reported to Oban as a
  failure so `max_attempts` retries it. Terminal refusals do not reach that
  path; the drain clears their markers and records `queue_error` instead. On
  the final attempt the drain returns every still-queued group to review with
  its last failure reason, so the job ends `:ok` rather than being discarded
  with rows stranded in Queued. Rows marked while that drain ran are left for
  the job that queued them.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 300, keys: [:library_path_id]]

  alias Mydia.ImportCandidates

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"library_path_id" => library_path_id}} = job) do
    final = final_attempt?(job)

    case ImportCandidates.drain_accepted(library_path_id,
           allow_episode_creation: true,
           final_attempt: final
         ) do
      {:ok, %{remaining: 0}} ->
        :ok

      # Rows left after the final attempt's give-up were marked mid-drain and
      # belong to the fresh job that queued them. Failing here would only get
      # this one discarded, with nothing left to retry.
      {:ok, %{remaining: _}} when final ->
        :ok

      {:ok, %{remaining: n}} ->
        {:error, "#{n} queued candidate(s) did not import"}
    end
  end

  # A hand-built %Oban.Job{} carries attempt 0 and max_attempts 20 by default,
  # which reads as "not final", the safe side.
  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max
end
