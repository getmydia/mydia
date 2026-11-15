defmodule MetadataRelay.Backup.Sweeper do
  @moduledoc """
  Runs `MetadataRelay.Backup.sweep/1` every `backup.sweep_interval_ms`, the way
  `MetadataRelay.PlayerLogs.Sweeper` does. An unset interval, as in test, means
  never: tests call `sweep/1` directly.
  """

  use GenServer

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      MetadataRelay.Backup.sweep()
    rescue
      error -> Logger.error("[Backup] Sweep failed: " <> Exception.message(error))
    end

    schedule()
    {:noreply, state}
  end

  defp schedule do
    case MetadataRelay.Backup.config(:sweep_interval_ms) do
      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :sweep, interval)

      _ ->
        :ok
    end
  end
end
