defmodule Mydia.Jobs.MisplacedSeriesHeal do
  @moduledoc """
  Manual-only self-heal for series files that landed in the wrong show folder.

  Runs `Mydia.Library.MisplacedSeriesHealer`. **Not scheduled** — moving library
  files based on title similarity is easy to get wrong (false matches, unusual
  release names, hardlinks still seeding). Enqueue explicitly after a dry-run:

      # Inspect first
      Mydia.Library.MisplacedSeriesHealer.heal(dry_run: true)

      # Then, if the plan looks right:
      Mydia.Jobs.MisplacedSeriesHeal.new(%{}) |> Oban.insert()

  Pass `"dry_run" => true` in job args to audit without moving files.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1

  require Logger

  alias Mydia.Library.MisplacedSeriesHealer

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    dry_run? = Map.get(args, "dry_run", false) == true

    Logger.info("Starting misplaced series file heal", dry_run: dry_run?)

    result = MisplacedSeriesHealer.heal(dry_run: dry_run?)

    Logger.info("Misplaced series file heal complete",
      dry_run: dry_run?,
      scanned: result.scanned,
      relocated: result.relocated,
      quarantined: result.quarantined,
      skipped: result.skipped,
      errors: result.errors
    )

    :ok
  end
end
