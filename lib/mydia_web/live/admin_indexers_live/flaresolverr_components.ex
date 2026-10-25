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
    <.admin_list id="flaresolverr" items={[@flaresolverr]}>
      <:row :let={flaresolverr}>
        <.admin_row id="flaresolverr-panel">
          <:title>
            <.icon name="hero-shield-check" class="w-4 h-4 opacity-70" /> FlareSolverr
            <.env_lock_badge
              :if={flaresolverr.env?}
              tip={gettext("Configured via environment variables")}
            />
          </:title>
          <:descriptor>
            <%= if flaresolverr.configured do %>
              <span class="font-mono">{flaresolverr.url}</span>
            <% else %>
              {gettext("Cloudflare bypass for protected indexers (not configured)")}
            <% end %>
          </:descriptor>
          <:badges>
            <span class={[
              "badge badge-sm badge-outline",
              if(flaresolverr.enabled, do: "badge-success", else: "badge-ghost")
            ]}>
              {if flaresolverr.enabled, do: gettext("Enabled"), else: gettext("Disabled")}
            </span>
            <%!-- Connection health, shown only when enabled (the Enabled/Disabled
                  badge already conveys the off state). --%>
            <%= if @flaresolverr_status.status != :disabled do %>
              <span class={[
                "badge badge-sm badge-outline",
                fs_badge_class(@flaresolverr_status.status)
              ]}>
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
          </:badges>
          <:actions>
            <.row_actions>
              <.row_action
                id="flaresolverr-row-test"
                icon="hero-signal"
                title={gettext("Test Connection")}
                phx-click="test_flaresolverr"
              />
              <.row_action
                id="flaresolverr-row-edit"
                icon="hero-pencil"
                title={gettext("Edit")}
                phx-click="edit_flaresolverr"
              />
            </.row_actions>
          </:actions>
        </.admin_row>
      </:row>
      <:empty>{gettext("FlareSolverr is unavailable.")}</:empty>
    </.admin_list>
    """
  end

  @doc """
  Renders the FlareSolverr edit modal.

  An `admin_modal` form (`Save` / `Cancel` / `Test`) over the four
  `flaresolverr.*` fields. Each field shows its ENV/DB/Default source; env-sourced
  fields render disabled (read-only) since environment variables win at runtime.
  `Test` probes the URL currently in the form, saved or not, regardless of the
  Enabled checkbox.

  `form` is the schemaless changeset form. `sources` maps each `flaresolverr.*` key
  to `:env`/`:database`/`:default`.
  """
  attr :form, :any, required: true
  attr :sources, :map, required: true

  def flaresolverr_modal(assigns) do
    ~H"""
    <.admin_modal
      id="flaresolverr-modal"
      icon="hero-shield-check"
      title="FlareSolverr"
      subtitle={gettext("Cloudflare bypass proxy")}
      on_close="close_flaresolverr_modal"
    >
      <.form
        for={@form}
        id="flaresolverr-form"
        phx-change="validate_flaresolverr"
        phx-submit="save_flaresolverr"
      >
        <p class="text-sm text-base-content/70 mb-4">
          {gettext(
            "FlareSolverr is a local proxy that solves Cloudflare challenges so Mydia can reach protected indexers. Configure the connection here, then enable Cloudflare bypass per-indexer in the list."
          )}
        </p>

        <.fs_modal_field
          field={@form[:enabled]}
          label={gettext("Enabled")}
          type="checkbox"
          source={@sources["flaresolverr.enabled"]}
        />
        <.fs_modal_field
          field={@form[:url]}
          label={gettext("URL")}
          type="text"
          placeholder="http://flaresolverr:8191"
          source={@sources["flaresolverr.url"]}
        />
        <.fs_modal_field
          field={@form[:timeout]}
          label={gettext("Timeout (ms)")}
          type="number"
          source={@sources["flaresolverr.timeout"]}
        />
        <.fs_modal_field
          field={@form[:max_timeout]}
          label={gettext("Max Timeout (ms)")}
          type="number"
          source={@sources["flaresolverr.max_timeout"]}
        />

        <.admin_modal_actions>
          <button
            id="flaresolverr-modal-test"
            type="button"
            class="btn btn-ghost gap-1.5"
            phx-click="test_flaresolverr_form"
          >
            <.icon name="hero-signal" class="w-4 h-4" /> {pgettext("verb", "Test")}
          </button>
          <button type="button" class="btn btn-ghost" phx-click="close_flaresolverr_modal">
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
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
        <.config_source_badge source={@source} size="xs" />
        <%= if @source == :env do %>
          <span class="text-xs text-base-content/50">
            {gettext("read-only (set via environment)")}
          </span>
        <% end %>
      </div>
      <.input field={@field} type={@type} placeholder={@placeholder} disabled={@source == :env} />
    </div>
    """
  end

  defp fs_status_icon(:healthy), do: "hero-check-circle"
  defp fs_status_icon(:unhealthy), do: "hero-x-circle"
  defp fs_status_icon(:loading), do: "hero-arrow-path"
  defp fs_status_icon(_), do: "hero-question-mark-circle"

  defp fs_badge_class(:healthy), do: "badge-success"
  defp fs_badge_class(:unhealthy), do: "badge-error"
  defp fs_badge_class(:loading), do: "badge-ghost"
  defp fs_badge_class(_), do: "badge-warning"

  defp fs_status_label(:healthy), do: gettext("Healthy")
  defp fs_status_label(:unhealthy), do: gettext("Unhealthy")
  defp fs_status_label(:loading), do: gettext("Checking…")
  defp fs_status_label(_), do: gettext("Unknown")

  defp fs_format_error({:connection_error, reason}),
    do:
      gettext("Connection error: %{reason}",
        reason: MydiaWeb.AdminIndexersLive.ErrorMessages.format_transport_reason(reason)
      )

  defp fs_format_error({:http_error, status, _}),
    do: gettext("HTTP error: %{status}", status: status)

  defp fs_format_error(:timeout), do: gettext("Connection timed out")
  defp fs_format_error(:not_configured), do: gettext("Not configured")
  defp fs_format_error(:disabled), do: gettext("Service is disabled")
  defp fs_format_error(:invalid_url), do: gettext("Not a valid http(s) URL")
  defp fs_format_error(error) when is_binary(error), do: error
  defp fs_format_error(error), do: inspect(error)
end
