defmodule Mydia.Jobs.UpgradeFinalize do
  @moduledoc """
  Decides whether a just-analyzed automatic-upgrade import actually beats the
  file it was grabbed to replace.

  Enqueued from the success branch of `Mydia.Library.apply_analysis/2` the
  moment a freshly-analyzed file carries a non-nil `supersedes_media_file_id`
  — the first point at which the new file can be scored, and therefore the
  first point this decision can be made. All of the comparison, trashing,
  blacklisting, and activity-trail work lives in
  `Mydia.Upgrades.finalize_upgrade/1`; this worker is a thin wrapper around
  it.

  `unique: [period: 3600, keys: [:media_file_id]]` collapses duplicate
  enqueues within the hour, but uniqueness alone does not make re-running
  this job safe by itself — `finalize_upgrade/1` clears
  `supersedes_media_file_id` in every terminal branch specifically so a
  second run (after the unique window lapses, or a manual retry) lands on
  `{:ok, :noop}` instead of re-trashing anything.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 5,
    unique: [period: 3600, keys: [:media_file_id]]

  alias Mydia.Upgrades

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_file_id" => media_file_id}}) do
    Upgrades.finalize_upgrade(media_file_id)
  end
end
