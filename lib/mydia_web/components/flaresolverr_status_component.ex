defmodule MydiaWeb.FlareSolverrStatusComponent do
  @moduledoc """
  Component for displaying FlareSolverr status in the admin config page.

  This component shows the FlareSolverr connection status and allows testing
  the connection. It only renders when FlareSolverr is configured.
  """
  use MydiaWeb, :html

  alias Mydia.Indexers.FlareSolverr

  @doc """
  Renders the FlareSolverr status card.

  Shows configuration status, health, and a test button.
  Only renders if FlareSolverr is configured (URL is set).
  """
  attr :flaresolverr_status, :map, required: true

  def flaresolverr_status_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-4 sm:p-6">
        <%!-- Header with status indicator --%>
        <div class="flex items-center justify-between mb-4">
          <div class="flex items-center gap-3">
            <div class={[
              "w-10 h-10 rounded-lg flex items-center justify-center",
              status_bg_class(@flaresolverr_status.status)
            ]}>
              <.icon
                name="hero-shield-check"
                class={"w-5 h-5 #{status_icon_class(@flaresolverr_status.status)}"}
              />
            </div>
            <div>
              <h3 class="font-semibold text-base">FlareSolverr</h3>
              <p class="text-xs text-base-content/60">Cloudflare bypass proxy</p>
            </div>
          </div>
          <div class={[
            "px-2.5 py-1 rounded-full text-xs font-medium",
            status_pill_class(@flaresolverr_status.status)
          ]}>
            {status_label(@flaresolverr_status.status)}
          </div>
        </div>

        <%= if @flaresolverr_status.configured do %>
          <%!-- Stats grid for healthy status --%>
          <%= if @flaresolverr_status.status == :healthy do %>
            <div class="grid grid-cols-2 gap-3 mb-4">
              <div class="bg-base-200/50 rounded-lg p-3">
                <div class="text-xs text-base-content/60 mb-1">Version</div>
                <div class="font-semibold text-sm">
                  {format_version(@flaresolverr_status.version)}
                </div>
              </div>
              <div class="bg-base-200/50 rounded-lg p-3">
                <div class="text-xs text-base-content/60 mb-1">Active Sessions</div>
                <div class="font-semibold text-sm">
                  {length(@flaresolverr_status.sessions || [])}
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Error display --%>
          <%= if @flaresolverr_status.status == :unhealthy and @flaresolverr_status.error do %>
            <div class="alert alert-error text-sm mb-4 py-2">
              <.icon name="hero-exclamation-circle" class="w-4 h-4" />
              <span>{format_error(@flaresolverr_status.error)}</span>
            </div>
          <% end %>

          <%!-- URL display --%>
          <div class="flex items-center gap-2 text-sm bg-base-200/50 rounded-lg px-3 py-2 mb-4">
            <.icon name="hero-link" class="w-4 h-4 text-base-content/50 shrink-0" />
            <code class="text-xs truncate flex-1">{@flaresolverr_status.url}</code>
          </div>

          <%!-- Action button --%>
          <button
            class={[
              "btn btn-sm w-full gap-2",
              if(@flaresolverr_status.status == :healthy, do: "btn-ghost", else: "btn-primary")
            ]}
            phx-click="test_flaresolverr"
          >
            <.icon name="hero-signal" class="w-4 h-4" /> Test Connection
          </button>
        <% else %>
          <%!-- Not configured state --%>
          <div class="text-center py-4">
            <div class="w-12 h-12 rounded-full bg-base-200 flex items-center justify-center mx-auto mb-3">
              <.icon name="hero-cog-6-tooth" class="w-6 h-6 text-base-content/40" />
            </div>
            <p class="text-sm text-base-content/70 mb-2">Not configured</p>
            <p class="text-xs text-base-content/50 mb-3">
              Configure FlareSolverr to bypass Cloudflare protection on supported indexers.
            </p>
            <.link
              navigate="/admin/config/settings"
              class="btn btn-sm btn-primary gap-2"
            >
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" /> Configure
            </.link>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Gets the current FlareSolverr status.

  Returns a map with:
  - configured: boolean indicating if FlareSolverr URL is set
  - status: :healthy, :unhealthy, or :disabled
  - url: the configured URL
  - version: FlareSolverr version (if healthy)
  - sessions: list of active sessions (if healthy)
  - error: error details (if unhealthy)
  """
  def get_status do
    config = FlareSolverr.config()

    if config && config.enabled && is_binary(config.url) && config.url != "" do
      case FlareSolverr.health_check() do
        {:ok, info} ->
          %{
            configured: true,
            status: :healthy,
            url: config.url,
            version: info[:version],
            sessions: info[:sessions] || []
          }

        {:error, reason} ->
          %{
            configured: true,
            status: :unhealthy,
            url: config.url,
            error: reason
          }
      end
    else
      %{
        configured: config != nil && is_binary(config[:url]) && config[:url] != "",
        status: :disabled,
        url: config && config[:url]
      }
    end
  end

  # Private helpers

  # Background color for the icon container
  defp status_bg_class(:healthy), do: "bg-success/10"
  defp status_bg_class(:unhealthy), do: "bg-error/10"
  defp status_bg_class(:disabled), do: "bg-base-200"
  defp status_bg_class(:loading), do: "bg-base-200"
  defp status_bg_class(_), do: "bg-warning/10"

  # Icon color
  defp status_icon_class(:healthy), do: "text-success"
  defp status_icon_class(:unhealthy), do: "text-error"
  defp status_icon_class(:disabled), do: "text-base-content/40"
  defp status_icon_class(:loading), do: "text-base-content/40"
  defp status_icon_class(_), do: "text-warning"

  # Status pill styling
  defp status_pill_class(:healthy), do: "bg-success/10 text-success"
  defp status_pill_class(:unhealthy), do: "bg-error/10 text-error"
  defp status_pill_class(:disabled), do: "bg-base-200 text-base-content/60"
  defp status_pill_class(:loading), do: "bg-base-200 text-base-content/60"
  defp status_pill_class(_), do: "bg-warning/10 text-warning"

  defp status_label(:healthy), do: "Healthy"
  defp status_label(:unhealthy), do: "Unhealthy"
  defp status_label(:disabled), do: "Disabled"
  defp status_label(:loading), do: "Checking..."
  defp status_label(:not_configured), do: "Not Configured"
  defp status_label(_), do: "Unknown"

  defp format_version(nil), do: "Unknown"
  defp format_version(version), do: version

  defp format_error({:connection_error, reason}), do: "Connection error: #{reason}"
  defp format_error({:http_error, status, _}), do: "HTTP error: #{status}"
  defp format_error(:timeout), do: "Connection timed out"
  defp format_error(:not_configured), do: "Not configured"
  defp format_error(:disabled), do: "Service is disabled"
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
