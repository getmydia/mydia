defmodule Mydia.Jobs.RemoveDownload do
  @moduledoc """
  Removes one download the operator asked to remove. See `Mydia.Downloads.Removal`.

  Runs on its own single-slot `:client_removals` queue. Transmission answers one
  RPC at a time, so a second removal running alongside would only wait inside
  the client and use up its own receive timeout.
  """

  use Oban.Worker,
    queue: :client_removals,
    max_attempts: 5,
    unique: [keys: [:download_id], states: :incomplete, period: :infinity]

  alias Mydia.Downloads.Removal

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"download_id" => download_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    Removal.perform(download_id, attempt >= max_attempts)
  end
end
