defmodule MydiaWeb.MediaLive.Show.TimelineComponents do
  @moduledoc """
  The history rail of the MediaLive.Show page.
  """
  use MydiaWeb, :html
  import MydiaWeb.MediaLive.Show.Formatters
  import MydiaWeb.Formatters, only: [format_file_size: 1]

  @doc """
  Timeline section showing history of events.

  Vertical, and positioned by the page grid rather than by its place in the
  main column: past the grid's container-query threshold it is the third
  column, and below it falls to a full-width row under the other two. See
  show.html.heex for the grid.

  It renders nothing at all on an item with no events, which is why the page
  grid picks its column template from `@timeline_events != []`.

  Collapsed, it renders at most five events (five dense rows measure 506px).
  Expanded, it renders everything it was given. At the three-column width the
  rail scrolls inside its own column rather than being sticky, so either state
  keeps its bottom reachable; see show.html.heex.
  """
  @timeline_visible_count 5

  attr :timeline_events, :list, required: true
  attr :display, Mydia.TimeDisplay, required: true
  attr :expanded, :boolean, default: false

  def timeline_section(assigns) do
    assigns =
      assigns
      |> assign(
        :shown_events,
        if(assigns.expanded,
          do: assigns.timeline_events,
          else: Enum.take(assigns.timeline_events, @timeline_visible_count)
        )
      )
      |> assign(
        :hidden_count,
        max(length(assigns.timeline_events) - @timeline_visible_count, 0)
      )

    ~H"""
    <%= if length(@timeline_events) > 0 do %>
      <div id="timeline-section" class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">{gettext("History")}</h2>
          <div class="relative">
            <%!-- The spine. Inset to the centre of the 32px icon nodes below
                  (left-4 is 16px), so every node sits on it. Spine and node
                  ring derive from base-content, not base-300: dark themes
                  disagree on whether base-300 is lighter or darker than the
                  base-200 card, and on Catppuccin it vanished. --%>
            <div class="absolute left-4 top-0 bottom-0 w-0.5 bg-base-content/15"></div>

            <div class="flex flex-col gap-3">
              <div
                :for={event <- @shown_events}
                class="relative flex items-start gap-3"
              >
                <%!-- Icon node on the spine --%>
                <div class="w-8 h-8 rounded-full bg-base-100 flex items-center justify-center border-2 border-base-content/20 shrink-0 z-10">
                  <.icon name={event.icon} class={"w-4 h-4 #{event.color}"} />
                </div>

                <%!-- Flat row rather than a nested card. Title and time share
                      one baseline, both single-line, so the row height is
                      driven by content and not by card padding. --%>
                <div class="flex-1 min-w-0 pt-0.5">
                  <div class="flex items-baseline justify-between gap-2">
                    <span class="font-semibold text-sm truncate" title={event.title}>{event.title}</span>
                    <time
                      class="text-xs text-base-content/50 whitespace-nowrap shrink-0"
                      title={format_absolute_time(event.timestamp, @display)}
                    >
                      {format_relative_time_short(event.timestamp)}
                    </time>
                  </div>
                  <div class="text-xs text-base-content/70 truncate" title={event.description}>
                    {event.description}
                  </div>
                  <%= if event.metadata do %>
                    <div class="flex flex-wrap gap-1 mt-1">
                      <%= if event.metadata[:quality] do %>
                        <span class="badge badge-primary badge-xs">
                          {format_download_quality(event.metadata.quality)}
                        </span>
                      <% end %>
                      <%= if event.metadata[:indexer] do %>
                        <span class="badge badge-outline badge-xs">
                          {event.metadata.indexer}
                        </span>
                      <% end %>
                      <%= if event.metadata[:resolution] do %>
                        <span class="badge badge-primary badge-xs">
                          {event.metadata.resolution}
                        </span>
                      <% end %>
                      <%= if event.metadata[:size] do %>
                        <span class="badge badge-ghost badge-xs">
                          {format_file_size(event.metadata.size)}
                        </span>
                      <% end %>
                      <%!-- w-full so the error takes its own line inside the
                            wrapping badge row rather than being squeezed into
                            the last badge's slot. --%>
                      <%= if event.metadata[:error] do %>
                        <div class="text-xs text-error mt-1 line-clamp-2 w-full">
                          <.icon name="hero-exclamation-circle" class="w-3 h-3 inline" />
                          {event.metadata.error}
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>

          <button
            :if={@hidden_count > 0}
            id="timeline-toggle"
            type="button"
            phx-click="toggle_timeline"
            aria-expanded={@expanded}
            class="btn btn-ghost btn-sm justify-start self-start mt-2 -mb-1"
          >
            {if @expanded,
              do: gettext("Show less"),
              else: gettext("Show %{count} more", count: @hidden_count)}
          </button>
        </div>
      </div>
    <% end %>
    """
  end
end
