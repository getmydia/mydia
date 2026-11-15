defmodule Mydia.Jobs.RemoveClientTorrent do
  @moduledoc """
  Removes one torrent from a download client by name and id, for a download
  row that is already gone: deleting a media item cascades its downloads away,
  and `Mydia.Media.Deletion` enqueues this in the same transaction so the
  client is told only when the delete commits (issue #1422).

  Shares the single-slot `:client_removals` queue with
  `Mydia.Jobs.RemoveDownload` for the same reason: Transmission answers one RPC
  at a time.
  """

  use Oban.Worker,
    queue: :client_removals,
    max_attempts: 5,
    unique: [keys: [:client, :client_id], states: :incomplete, period: :infinity]

  require Logger

  alias Mydia.Downloads.ClientRemoval

  @doc "The job for one torrent."
  @spec new_for(String.t(), String.t(), boolean()) :: Ecto.Changeset.t()
  def new_for(client, client_id, delete_files) do
    new(%{"client" => client, "client_id" => client_id, "delete_files" => delete_files})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"client" => client, "client_id" => client_id, "delete_files" => delete_files}
      }) do
    case ClientRemoval.remove_torrent(client, client_id, delete_files) do
      :ok ->
        :ok

      # The client was removed or disabled since: nothing left to tell.
      {:error, :no_client} ->
        Logger.info("Not removing a deleted item's torrent: its client is gone",
          client: client,
          client_id: client_id
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
