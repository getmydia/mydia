defmodule MydiaWeb.Components.ErrorBoundary do
  @moduledoc """
  Error boundary component for graceful error handling in LiveViews.

  This component provides a way to catch and display errors without crashing
  the entire page, improving user experience and making debugging easier.

  ## Usage

  Wrap a section of your LiveView template with the error boundary:

      <.error_boundary id="quality-profiles-section" error={@quality_profiles_error}>
        <%!-- Your content that might fail --%>
        <div :for={profile <- @quality_profiles}>
          <%= profile.name %>
        </div>
      </.error_boundary>

  In your LiveView, initialize the error state in mount:

      def mount(_params, _session, socket) do
        {:ok,
         socket
         |> assign(:quality_profiles_error, nil)
         |> assign(:quality_profiles, [])}
      end

  When an error occurs, update the error state:

      def handle_event("load_profiles", _, socket) do
        try do
          profiles = Settings.list_quality_profiles()
          {:noreply, assign(socket, quality_profiles: profiles, quality_profiles_error: nil)}
        rescue
          error ->
            MydiaLogger.log_error(:liveview, "Failed to load quality profiles",
              error: error,
              stacktrace: __STACKTRACE__
            )
            {:noreply, assign(socket, quality_profiles_error: Exception.message(error))}
        end
      end
  """

  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :error, :any, default: nil

  attr :title, :string,
    default: nil,
    doc: "heading shown on error; defaults to a translated \"Something went wrong\""

  attr :show_retry, :boolean, default: true
  attr :retry_event, :string, default: nil
  slot :inner_block, required: true

  def error_boundary(assigns) do
    ~H"""
    <div id={@id} class="error-boundary-container">
      <%= if @error do %>
        <div class="alert alert-error shadow-lg">
          <div>
            <.icon name="hero-exclamation-triangle" class="w-6 h-6" />
            <div>
              <h3 class="font-bold">{@title || gettext("Something went wrong")}</h3>
              <div class="text-sm">
                <%= if is_binary(@error) do %>
                  {@error}
                <% else %>
                  {gettext("An unexpected error occurred. Our team has been notified.")}
                <% end %>
              </div>
            </div>
          </div>
          <%= if @show_retry && @retry_event do %>
            <div class="flex-none">
              <button
                phx-click={@retry_event}
                class="btn btn-sm btn-ghost"
                type="button"
              >
                {gettext("Try Again")}
              </button>
            </div>
          <% end %>
        </div>
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </div>
    """
  end

  @doc """
  Inline error display for smaller error messages within forms or sections.
  """
  attr :error, :any, default: nil
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def error_fallback(assigns) do
    ~H"""
    <%= if @error do %>
      <div class={["alert alert-warning", @class]}>
        <.icon name="hero-exclamation-circle" class="w-5 h-5" />
        <span class="text-sm">
          <%= if is_binary(@error) do %>
            {@error}
          <% else %>
            {gettext("An error occurred")}
          <% end %>
        </span>
      </div>
    <% else %>
      {render_slot(@inner_block)}
    <% end %>
    """
  end
end
