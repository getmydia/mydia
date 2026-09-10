defmodule MydiaWeb.AdminIndexersLive.FlareSolverrComponents do
  @moduledoc """
  FlareSolverr summary row and edit modal for the Indexers tab.

  Extracted from `MydiaWeb.AdminIndexersLive.Components` to keep that file
  focused on the indexer lists. Rendering only; all events are handled by
  `MydiaWeb.AdminIndexersLive.Index`.
  """
  use MydiaWeb, :html

  @doc """
  Renders the FlareSolverr summary row at the top of the Indexers tab.

  Follows the same row convention as the indexer and download-client lists: name,
  a descriptor (the URL or a not-configured hint), ENV/enabled/health badges, and
  Test + Edit actions. Editing opens `flaresolverr_modal/1`. The row always renders
  so an operator can reach the controls even when FlareSolverr is unconfigured.

  `flaresolverr` is the summary map (`:enabled`, `:url`, `:configured`, `:env?`).
  `flaresolverr_status` is the map from `Mydia.Indexers.FlareSolverr.status/0`
  (plus the `:loading` first-paint state).
  """
  attr :flaresolverr, :map, required: true
  attr :flaresolverr_status, :map, required: true

  def flaresolverr_row(assigns) do
    ~H"""
    <div id="flaresolverr-panel" class="bg-base-200 rounded-box">
      <div class="p-3 sm:p-4">
        <div class="flex flex-col sm:flex-row sm:items-center gap-3">
          <div class="flex-1 min-w-0">
            <div class="font-semibold flex items-center gap-2 flex-wrap">
              <.icon name="hero-shield-check" class="w-4 h-4 opacity-70" /> FlareSolverr
              <%= if @flaresolverr.env? do %>
                <span
                  class="badge badge-primary badge-xs tooltip"
                  data-tip="Configured via environment variables"
                >
                  <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
                </span>
              <% end %>
            </div>
            <div class="text-xs opacity-60 mt-1 truncate">
              <%= if @flaresolverr.configured do %>
                <span class="font-mono">{@flaresolverr.url}</span>
              <% else %>
                Cloudflare bypass for protected indexers (not configured)
              <% end %>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <span class={[
              "badge badge-sm",
              if(@flaresolverr.enabled, do: "badge-success", else: "badge-ghost")
            ]}>
              {if @flaresolverr.enabled, do: "Enabled", else: "Disabled"}
            </span>
            <%!-- Connection health, shown only when enabled (the Enabled/Disabled
                  badge already conveys the off state). --%>
            <%= if @flaresolverr_status.status != :disabled do %>
              <span class={["badge badge-sm", fs_badge_class(@flaresolverr_status.status)]}>
                <.icon name={fs_status_icon(@flaresolverr_status.status)} class="w-3 h-3 mr-1" />
                {fs_status_label(@flaresolverr_status.status)}
              </span>
              <%= if @flaresolverr_status.status == :unhealthy and @flaresolverr_status[:error] do %>
                <div
                  class="tooltip tooltip-left"
                  data-tip={fs_format_error(@flaresolverr_status.error)}
                >
                  <.icon name="hero-information-circle" class="w-4 h-4 text-error" />
                </div>
              <% end %>
            <% end %>

            <div class="join ml-auto sm:ml-2">
              <button
                id="flaresolverr-row-test"
                class="btn btn-sm btn-ghost join-item"
                phx-click="test_flaresolverr"
                title="Test Connection"
              >
                <.icon name="hero-signal" class="w-4 h-4" />
              </button>
              <button
                class="btn btn-sm btn-ghost join-item"
                phx-click="edit_flaresolverr"
                title="Edit"
              >
                <.icon name="hero-pencil" class="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the FlareSolverr edit modal.

  A standard `modal-box` form (`Save` / `Cancel` / `Test`) over the four
  `flaresolverr.*` fields. Each field shows its ENV/DB/Default source; env-sourced
  fields render disabled (read-only) since environment variables win at runtime.

  `form` is the schemaless changeset form. `sources` maps each `flaresolverr.*` key
  to `:env`/`:database`/`:default`.
  """
  attr :form, :any, required: true
  attr :sources, :map, required: true

  def flaresolverr_modal(assigns) do
    ~H"""
    <div class="modal modal-open" id="flaresolverr-modal">
      <div class="modal-box max-w-lg">
        <.form
          for={@form}
          id="flaresolverr-form"
          phx-change="validate_flaresolverr"
          phx-submit="save_flaresolverr"
        >
          <div class="flex items-center gap-3 mb-4">
            <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
              <.icon name="hero-shield-check" class="w-5 h-5 text-primary" />
            </div>
            <div>
              <h3 class="font-semibold text-lg">FlareSolverr</h3>
              <p class="text-xs text-base-content/60">Cloudflare bypass proxy</p>
            </div>
          </div>

          <p class="text-sm text-base-content/70 mb-4">
            FlareSolverr is a local proxy that solves Cloudflare challenges so Mydia can reach
            protected indexers. Configure the connection here, then enable Cloudflare bypass
            per-indexer in the list.
          </p>

          <.fs_modal_field
            field={@form[:enabled]}
            label="Enabled"
            type="checkbox"
            source={@sources["flaresolverr.enabled"]}
          />
          <.fs_modal_field
            field={@form[:url]}
            label="URL"
            type="text"
            placeholder="http://flaresolverr:8191"
            source={@sources["flaresolverr.url"]}
          />
          <.fs_modal_field
            field={@form[:timeout]}
            label="Timeout (ms)"
            type="number"
            source={@sources["flaresolverr.timeout"]}
          />
          <.fs_modal_field
            field={@form[:max_timeout]}
            label="Max Timeout (ms)"
            type="number"
            source={@sources["flaresolverr.max_timeout"]}
          />

          <div class="modal-action">
            <button type="button" class="btn btn-ghost btn-sm gap-1.5" phx-click="test_flaresolverr">
              <.icon name="hero-signal" class="w-4 h-4" /> Test
            </button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="close_flaresolverr_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm">Save</button>
          </div>
        </.form>
      </div>
      <label class="modal-backdrop" phx-click="close_flaresolverr_modal">Close</label>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :placeholder, :string, default: nil
  attr :source, :atom, required: true

  defp fs_modal_field(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-2">
        <span class="text-sm font-medium">{@label}</span>
        <.fs_source_badge source={@source} />
        <%= if @source == :env do %>
          <span class="text-xs text-base-content/50">read-only (set via environment)</span>
        <% end %>
      </div>
      <.input field={@field} type={@type} placeholder={@placeholder} disabled={@source == :env} />
    </div>
    """
  end

  attr :source, :atom, required: true

  defp fs_source_badge(assigns) do
    ~H"""
    <%= case @source do %>
      <% :env -> %>
        <span class="badge badge-info badge-xs">ENV</span>
      <% :database -> %>
        <span class="badge badge-primary badge-xs">DB</span>
      <% _ -> %>
        <span class="badge badge-ghost badge-xs">Default</span>
    <% end %>
    """
  end

  defp fs_status_icon(:healthy), do: "hero-check-circle"
  defp fs_status_icon(:unhealthy), do: "hero-x-circle"
  defp fs_status_icon(:disabled), do: "hero-minus-circle"
  defp fs_status_icon(:loading), do: "hero-arrow-path"
  defp fs_status_icon(_), do: "hero-question-mark-circle"

  defp fs_badge_class(:healthy), do: "badge-success"
  defp fs_badge_class(:unhealthy), do: "badge-error"
  defp fs_badge_class(:disabled), do: "badge-ghost"
  defp fs_badge_class(:loading), do: "badge-ghost"
  defp fs_badge_class(_), do: "badge-warning"

  defp fs_status_label(:healthy), do: "Healthy"
  defp fs_status_label(:unhealthy), do: "Unhealthy"
  defp fs_status_label(:disabled), do: "Disabled"
  defp fs_status_label(:loading), do: "Checking…"
  defp fs_status_label(_), do: "Unknown"

  defp fs_format_error({:connection_error, reason}), do: "Connection error: #{reason}"
  defp fs_format_error({:http_error, status, _}), do: "HTTP error: #{status}"
  defp fs_format_error(:timeout), do: "Connection timed out"
  defp fs_format_error(:not_configured), do: "Not configured"
  defp fs_format_error(:disabled), do: "Service is disabled"
  defp fs_format_error(:invalid_url), do: "Not a valid http(s) URL"
  defp fs_format_error(error) when is_binary(error), do: error
  defp fs_format_error(error), do: inspect(error)
end
