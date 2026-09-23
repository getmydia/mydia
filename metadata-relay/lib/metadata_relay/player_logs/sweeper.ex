defmodule MetadataRelay.PlayerLogs.Sweeper do
  @moduledoc """
  Runs `MetadataRelay.PlayerLogs.sweep/1` every `player_logs.sweep_interval_ms`,
  the way `MetadataRelay.Cache.InMemory` schedules its cleanup. An unset
  interval, as in test, means never: tests call `sweep/1` directly.
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
      MetadataRelay.PlayerLogs.sweep()
    rescue
      error -> Logger.error("[PlayerLogs] Sweep failed: " <> Exception.message(error))
    end

    schedule()
    {:noreply, state}
  end

  defp schedule do
    case MetadataRelay.PlayerLogs.config(:sweep_interval_ms) do
      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :sweep, interval)

      _ ->
        :ok
    end
  end
end
