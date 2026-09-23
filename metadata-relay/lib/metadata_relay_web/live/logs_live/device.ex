defmodule MetadataRelayWeb.LogsLive.Device do
  @moduledoc """
  One device's sessions, each linking to its lines at `/logs/raw`.
  """

  use Phoenix.LiveView

  alias MetadataRelay.PlayerLogs

  @impl true
  def mount(%{"device_id" => device_id}, _session, socket) do
    case PlayerLogs.get_device(device_id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "No logs from that device.") |> push_navigate(to: "/logs")}

      device ->
        {:ok,
         socket
         |> assign(:page_title, device.name || "Device")
         |> assign(:device, device)
         |> assign(:sessions, PlayerLogs.device_sessions(device.device_id))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <MetadataRelayWeb.Layouts.app flash={@flash}>
      <section id="log-device-page" class="space-y-6">
        <header class="space-y-2">
          <.link navigate="/logs" class="link link-hover text-sm">All devices</.link>
          <h1 class="text-3xl font-semibold tracking-tight">{@device.name || "Unnamed device"}</h1>
          <p class="text-sm text-base-content/60">
            <span class="font-mono">{@device.device_id}</span>
            · {@device.platform} {@device.os_version} · app {@device.app_version}
          </p>
          <a href={"/logs/raw?" <> URI.encode_query(%{"device" => @device.device_id, "since" => "1h"})} class="btn btn-sm btn-primary">
            Last hour as text
          </a>
        </header>

        <section class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body gap-4">
            <h2 class="card-title text-lg">Sessions</h2>
            <div class="overflow-x-auto">
              <table id="log-sessions" class="table">
                <thead>
                  <tr>
                    <th>Session</th>
                    <th>From</th>
                    <th>To</th>
                    <th>Lines</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={session <- @sessions} id={"log-session-#{session.sid || "none"}"} class="hover">
                    <td>
                      <a href={session_url(@device, session)} class="link link-hover font-mono">{session.sid || "none"}</a>
                    </td>
                    <td>{format_ms(session.first_t)}</td>
                    <td>{format_ms(session.last_t)}</td>
                    <td>{session.lines}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </section>
    </MetadataRelayWeb.Layouts.app>
    """
  end

  defp session_url(device, session) do
    "/logs/raw?" <>
      URI.encode_query(%{
        "device" => device.device_id,
        "session" => session.sid || "",
        "since" => iso(session.first_t),
        "until" => iso(session.last_t)
      })
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp format_ms(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
end
