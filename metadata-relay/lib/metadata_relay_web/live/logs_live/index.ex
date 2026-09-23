defmodule MetadataRelayWeb.LogsLive.Index do
  @moduledoc """
  Maintainer dashboard: the devices that have shared their logs, and the
  reports sent with a code. The lines themselves are at `/logs/raw`.
  """

  use Phoenix.LiveView

  alias MetadataRelay.PlayerLogs

  @impl true
  def mount(_params, _session, socket) do
    devices = PlayerLogs.list_devices()

    {:ok,
     socket
     |> assign(:page_title, "Player logs")
     |> assign(:devices, devices)
     |> assign(:device_names, Map.new(devices, &{&1.device_id, &1.name}))
     |> assign(:active, PlayerLogs.active_device_ids(DateTime.add(DateTime.utc_now(), -3_600)))
     |> assign(:reports, PlayerLogs.list_recent_reports(50))}
  end

  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
