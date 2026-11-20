defmodule Mydia.Downloads.ListStatusAdapter do
  @moduledoc """
  A download client adapter whose `list_torrents/2` returns the statuses set
  with `put/1`. Register it for a client type in a non-async test, restore the
  original in `on_exit`, and call `clear/0` there too.
  """
  @behaviour Mydia.Downloads.Client

  alias Mydia.Downloads.Client.Error

  def put(statuses), do: :persistent_term.put({__MODULE__, :statuses}, statuses)

  def clear, do: :persistent_term.erase({__MODULE__, :statuses})

  @impl true
  def list_torrents(_config, _opts),
    do: {:ok, :persistent_term.get({__MODULE__, :statuses}, [])}

  @impl true
  def supported_protocols, do: [:torrent]
  @impl true
  def test_connection(_config), do: {:error, Error.unknown("not implemented")}
  @impl true
  def add_torrent(_config, _torrent, _opts), do: {:error, Error.unknown("not implemented")}
  @impl true
  def get_status(_config, _client_id), do: {:error, Error.unknown("not implemented")}
  @impl true
  def pause_torrent(_config, _client_id), do: :ok
  @impl true
  def resume_torrent(_config, _client_id), do: :ok
  @impl true
  def remove_torrent(_config, _client_id, _opts), do: :ok
end
