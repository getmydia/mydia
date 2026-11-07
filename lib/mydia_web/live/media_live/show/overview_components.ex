defmodule MydiaWeb.MediaLive.Show.OverviewComponents do
  @moduledoc """
  The media page's overview: the overview text with the Trailer and Crew
  buttons beside it, and the cast row under it.
  """

  use MydiaWeb, :html

  import MydiaWeb.MediaLive.Show.Helpers,
    only: [get_cast: 2, get_crew: 1, get_overview: 1, trailer_videos: 1]

  alias MydiaWeb.PersonComponents

  # The row scrolls sideways, so this reaches past the leads without costing
  # height; TMDB metadata stores the first 20 billed.
  @cast_row_size 15

  @doc """
  The overview text, a Trailer button when the item has one, a Crew dropdown
  listing the key crew, and the first #{@cast_row_size} billed cast as a
  sideways-scrolling row of avatar cards, always visible.
  """
  attr :media_item, :map, required: true

  def overview_section(assigns) do
    assigns =
      assigns
      |> assign(:cast, get_cast(assigns.media_item, @cast_row_size))
      |> assign(:crew, get_crew(assigns.media_item))
      |> assign(:has_trailer, trailer_videos(assigns.media_item) != [])

    ~H"""
    <div class="mb-4 space-y-4 text-sm">
      <div class="flex flex-wrap items-start gap-4">
        <p class="flex-1 min-w-[200px] text-base-content/70 leading-relaxed line-clamp-2">
          {get_overview(@media_item)}
        </p>

        <%!-- ml-auto keeps the buttons on the right edge when the row wraps
              them onto their own line, so the Crew dropdown-end panel opens
              leftward and stays on screen. --%>
        <div class="flex items-center gap-2 flex-shrink-0 ml-auto">
          <button
            :if={@has_trailer}
            id="trailer-button"
            type="button"
            phx-click="show_trailer_modal"
            class="btn btn-sm 2xl:btn-md btn-soft btn-primary gap-1.5"
          >
            <.icon name="hero-play-circle" class="w-4 h-4 2xl:w-5 2xl:h-5" />
            <span>{gettext("Trailer")}</span>
          </button>

          <div :if={@crew != []} class="dropdown dropdown-end">
            <div
              id="crew-button"
              tabindex="0"
              role="button"
              class="btn btn-sm 2xl:btn-md btn-soft btn-primary gap-1.5"
            >
              <.icon name="hero-users" class="w-4 h-4 2xl:w-5 2xl:h-5" />
              <span>{gettext("Crew")}</span>
              <.icon name="hero-chevron-down" class="w-3 h-3 2xl:w-4 2xl:h-4 opacity-60" />
            </div>
            <div
              tabindex="0"
              class="dropdown-content z-50 card card-compact w-72 max-w-[calc(100vw-2rem)] p-2 shadow-xl bg-base-100 border border-base-300"
            >
              <div id="crew-list" class="card-body p-3 space-y-1">
                <div :for={member <- @crew} class="text-sm">
                  <span class="font-medium">{member.name}</span>
                  <span class="text-base-content/60">· {member.job}</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Its own id prefix: the title dialog can render the same actor at
            the same time, under the default prefix. --%>
      <div
        :if={@cast != []}
        id="media-cast-row"
        role="list"
        aria-label={gettext("Cast")}
        class="flex gap-3 overflow-x-auto pb-2 snap-x"
      >
        <div
          :for={{actor, index} <- Enum.with_index(@cast)}
          role="listitem"
          class="w-24 shrink-0 snap-start"
        >
          <PersonComponents.cast_person
            member={actor}
            index={index}
            event="show_person"
            id_prefix="media-cast-person"
          />
        </div>
      </div>
    </div>
    """
  end
end
