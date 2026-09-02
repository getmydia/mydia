defmodule MydiaWeb.Live.Components.TrendingDetailModal do
  @moduledoc """
  A LiveComponent for displaying detailed information about trending movies/TV shows.

  Shows a rich modal with backdrop image, synopsis, cast, ratings, and trailers
  when clicking on trending items from the dashboard.

  ## Usage

      <.live_component
        module={MydiaWeb.Live.Components.TrendingDetailModal}
        id="trending-detail-modal"
        item={@selected_item}
        metadata={@selected_metadata}
        loading={@detail_loading}
        current_user={@current_user}
        open={@selected_item != nil}
        config_open={false}
      />

  The box is a flex column: a fixed header, then one scrolling child. Any new
  content belongs inside `#trending-detail-modal-body`, not as a sibling of it,
  or it will sit outside the scroll region and be unreachable. There is no
  footer; all actions live in the header's `#trending-detail-modal-actions`
  cluster.

  ## Events

  The component emits these events to the parent LiveView:

  - `close_details` - When user closes the modal
  - `add_to_library` - When user clicks "Add to Library" (with tmdb_id and
    media_type params). Overridable per host with `add_event`; `request_event`
    does the same for the guest Request button. A host whose add handler is
    named differently must pass them or the first click raises.

  ## `actions` slot

  Optional. Dashboard and Discovery render the default header action set
  (Add to Library / Request / "Go to"). The two request pages pass their own
  `:actions` slot instead, which renders inside `#trending-detail-modal-actions`
  and replaces the defaults outright, because Add to Library there would
  create the media item while leaving the request pending.

  ## `config_open`

  Every host LiveView also renders `MydiaWeb.AddMediaComponents.add_config_modal/1`
  once per page, at `z-[1000]`, above this modal's `z-999`. It can be opened
  from a caret inside this modal's own header actions and recommendations rail,
  and both dialogs bind `phx-window-keydown` with `phx-key="Escape"` as a
  workaround for `open`-attribute dialogs getting no native Escape handling.
  `phx-window-keydown` is not scoped by visual stacking, so without
  `config_open` a single Escape press would close both layers at once instead of
  only the top one.

  Every caller must pass `config_open`, whether the configure-before-adding
  dialog is currently open for this LiveView. There is deliberately no default:
  a future caller that forgets it fails loudly at render instead of silently
  regressing Escape handling. A caller with no configure dialog of its own (the
  two request pages) always passes `config_open={false}`.
  """
  use MydiaWeb, :live_component

  alias Mydia.Metadata.Ref
  alias Mydia.Metadata.Structs.Video

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :item_ref, item_ref(assigns.item))

    ~H"""
    <dialog
      id={@id}
      class="modal"
      open={@open}
      phx-window-keydown={@open && not @config_open && "close_details"}
      phx-key="Escape"
    >
      <%= if @open do %>
        <div class="modal-box max-w-5xl w-11/12 max-h-[90vh] p-0 flex flex-col overflow-hidden">
          <%!-- Header with backdrop --%>
          <div class="relative h-48 md:h-64 bg-base-300 shrink-0">
            <%= if backdrop_path(@item, @metadata) do %>
              <img
                src={ImageUrl.backdrop_url(backdrop_path(@item, @metadata), "w1280")}
                alt=""
                class="w-full h-full object-cover"
              />
              <div class="absolute inset-0 bg-gradient-to-t from-base-100 via-base-100/50 to-transparent">
              </div>
            <% else %>
              <div class="w-full h-full bg-gradient-to-br from-primary/20 to-secondary/20"></div>
            <% end %>

            <%!-- Close button. Icon-only and always present regardless of what
                 a caller's :actions slot puts beside it in the header, so
                 aria-label carries its accessible name. --%>
            <button
              phx-click="close_details"
              aria-label="Close"
              class="btn btn-circle btn-ghost btn-sm absolute top-4 right-4 z-10 bg-base-100/50 hover:bg-base-100"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>

            <%!-- Title overlay --%>
            <div class="absolute bottom-0 left-0 right-0 p-4 md:p-6">
              <div class="flex flex-wrap items-end gap-4">
                <%= if poster_path(@item, @metadata) do %>
                  <img
                    src={ImageUrl.poster_url(poster_path(@item, @metadata), "w185")}
                    alt={title(@item, @metadata)}
                    class="w-20 md:w-28 rounded-lg shadow-xl hidden sm:block"
                  />
                <% end %>
                <div class="flex-1">
                  <h2 class="text-2xl md:text-3xl font-bold text-white drop-shadow-lg">
                    {title(@item, @metadata)}
                  </h2>
                  <div class="flex flex-wrap items-center gap-2 mt-1">
                    <%= if year(@item, @metadata) do %>
                      <span class="badge badge-ghost">{year(@item, @metadata)}</span>
                    <% end %>
                    <%= if vote_average(@item, @metadata) do %>
                      <span class="badge badge-warning gap-1">
                        <.icon name="hero-star-solid" class="w-3 h-3" />
                        {Float.round(vote_average(@item, @metadata), 1)}
                      </span>
                    <% end %>
                    <%= if runtime(@metadata) do %>
                      <span class="badge badge-ghost">{format_runtime(runtime(@metadata))}</span>
                    <% end %>
                    <%= if format_seasons(seasons(@metadata)) do %>
                      <span class="badge badge-ghost">
                        {format_seasons(seasons(@metadata))}
                      </span>
                    <% end %>
                    <%= if genres(@metadata) != [] do %>
                      <span class="text-white/40">•</span>
                    <% end %>
                    <%= for genre <- genres(@metadata) do %>
                      <span class="badge badge-outline">{genre}</span>
                    <% end %>
                  </div>
                </div>
                <div
                  id="trending-detail-modal-actions"
                  class="flex flex-wrap items-center gap-2 shrink-0"
                >
                  <%= if @actions != [] do %>
                    {render_slot(@actions)}
                  <% else %>
                    <%= if not in_library?(@item) do %>
                      <%= if @current_user && @current_user.role == "guest" do %>
                        <button
                          phx-click={@request_event}
                          phx-value-ref={@item_ref}
                          phx-value-media_type={media_type_string(@item)}
                          disabled={Map.get(@item, :request_status) != nil}
                          class="btn btn-primary"
                        >
                          <%= if Map.get(@item, :request_status) do %>
                            <.icon name="hero-check" class="w-4 h-4" /> Requested
                          <% else %>
                            <.icon name="hero-paper-airplane" class="w-4 h-4" /> Request
                          <% end %>
                        </button>
                      <% else %>
                        <div class="join">
                          <button
                            phx-click={@add_event}
                            phx-value-ref={@item_ref}
                            phx-value-media_type={media_type_string(@item)}
                            class="btn btn-primary join-item"
                          >
                            <.icon name="hero-plus" class="w-4 h-4" /> Add to Library
                          </button>
                          <.library_picker_button
                            ref={@item_ref}
                            media_type={media_type_string(@item)}
                            title={@item.title}
                          />
                        </div>
                      <% end %>
                    <% else %>
                      <.link navigate={library_path(@item)} class="btn btn-ghost">
                        <.icon name="hero-arrow-right" class="w-4 h-4" />
                        Go to {media_type_label(@item)}
                      </.link>
                    <% end %>
                  <% end %>
                </div>
              </div>
            </div>
          </div>

          <div id="trending-detail-modal-body" class="flex-1 overflow-y-auto">
            <%!-- Body content --%>
            <div class="p-4 md:p-6">
              <%= if @loading do %>
                <div class="flex items-center justify-center py-12">
                  <span class="loading loading-spinner loading-lg"></span>
                  <span class="ml-3 text-base-content/70">Loading details...</span>
                </div>
              <% else %>
                <div class="space-y-6">
                  <%!-- Trailer --%>
                  <%= if first_trailer(@metadata) do %>
                    <div>
                      <h3 class="text-lg font-semibold mb-3">Trailer</h3>
                      <div class="aspect-video rounded-lg overflow-hidden bg-base-300">
                        <iframe
                          src={
                            Video.youtube_embed_url(first_trailer(@metadata)) <>
                              "?rel=0&modestbranding=1"
                          }
                          title="Trailer"
                          class="w-full h-full"
                          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
                          allowfullscreen
                        ></iframe>
                      </div>
                    </div>
                  <% end %>

                  <%!-- Synopsis --%>
                  <%= if overview(@item, @metadata) do %>
                    <div>
                      <h3 class="text-lg font-semibold mb-2">Synopsis</h3>
                      <p class="text-base-content/80 leading-relaxed">
                        {overview(@item, @metadata)}
                      </p>
                    </div>
                  <% end %>

                  <%!-- Cast --%>
                  <%= if cast(@metadata) != [] do %>
                    <div>
                      <h3 class="text-lg font-semibold mb-3">Cast</h3>
                      <div class="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-6 gap-3">
                        <%= for member <- Enum.take(cast(@metadata), 6) do %>
                          <div class="text-center">
                            <%= if member.profile_path do %>
                              <img
                                src={ImageUrl.profile_url(member.profile_path)}
                                alt={member.name}
                                class="w-16 h-16 md:w-20 md:h-20 rounded-full object-cover mx-auto mb-2"
                              />
                            <% else %>
                              <div class="w-16 h-16 md:w-20 md:h-20 rounded-full bg-base-300 flex items-center justify-center mx-auto mb-2">
                                <.icon name="hero-user" class="w-8 h-8 text-base-content/30" />
                              </div>
                            <% end %>
                            <p class="text-sm font-medium line-clamp-1">{member.name}</p>
                            <%= if member.character do %>
                              <p class="text-xs text-base-content/60 line-clamp-1">
                                {member.character}
                              </p>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <%!-- Optional trailing content, e.g. a recommendations rail. Rendered
                 inside the scrolling body so it scrolls with it; a rail placed
                 beside the <dialog> would sit behind the backdrop. --%>
            <div :if={@rail != []} class="px-4 md:px-6 pb-4">
              {render_slot(@rail)}
            </div>
          </div>
        </div>

        <%!-- Backdrop --%>
        <div class="modal-backdrop bg-black/70">
          <button type="button" phx-click="close_details">close</button>
        </div>
      <% end %>
    </dialog>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open, fn -> false end)
     |> assign_new(:loading, fn -> false end)
     |> assign_new(:metadata, fn -> nil end)
     # Optional slot: the dashboard renders this modal without one.
     |> assign_new(:rail, fn -> [] end)
     # Optional slot: Dashboard and Discovery render the default header actions.
     |> assign_new(:actions, fn -> [] end)
     # The primary action is the dialog's event contract with its host, exactly
     # as it is for trending_card/1: emitting an event the host does not handle
     # raises FunctionClauseError and kills the LiveView on the first click.
     # Discover, the Dashboard and the request pages all keep the defaults.
     |> assign_new(:add_event, fn -> "add_to_library" end)
     |> assign_new(:request_event, fn -> "request_media" end)}
  end

  # Helper functions for accessing data from either SearchResult (item) or MediaMetadata

  # `@item` is nil while the modal is closed (`open={@selected_item != nil}`),
  # and `render/1` runs on every diff regardless, so this guards against
  # building a ref out of nothing on a render the template never uses it in.
  defp item_ref(nil), do: nil
  defp item_ref(item), do: Ref.to_param(Ref.from_search_result(item))

  defp title(item, nil), do: item.title
  defp title(_item, metadata), do: metadata.title

  defp year(item, nil), do: item.year
  defp year(_item, metadata), do: metadata.year

  defp poster_path(item, nil), do: item.poster_path
  defp poster_path(_item, metadata), do: metadata.poster_path

  defp backdrop_path(item, nil), do: item.backdrop_path
  defp backdrop_path(_item, metadata), do: metadata.backdrop_path

  defp overview(item, nil), do: item.overview
  defp overview(_item, metadata), do: metadata.overview

  defp vote_average(item, nil), do: item.vote_average
  defp vote_average(_item, metadata), do: metadata.vote_average

  defp runtime(nil), do: nil
  defp runtime(metadata), do: metadata.runtime

  defp seasons(nil), do: nil
  defp seasons(metadata), do: metadata.number_of_seasons

  defp genres(nil), do: []
  defp genres(metadata), do: metadata.genres || []

  defp cast(nil), do: []
  defp cast(metadata), do: metadata.cast || []

  defp first_trailer(nil), do: nil

  defp first_trailer(metadata) do
    case metadata.videos do
      [video | _] -> video
      _ -> nil
    end
  end

  defp in_library?(nil), do: false
  defp in_library?(item), do: Map.get(item, :in_library, false)

  defp media_type_string(item) do
    case item.media_type do
      :movie -> "movie"
      :tv_show -> "tv_show"
      _ -> "movie"
    end
  end

  defp media_type_label(item) do
    case item.media_type do
      :movie -> "Movie"
      :tv_show -> "Show"
      _ -> "Movie"
    end
  end

  defp library_path(item) do
    case item.media_type do
      :movie -> "/movies/#{item.id}"
      :tv_show -> "/tv/#{item.id}"
      _ -> "/movies/#{item.id}"
    end
  end

  defp format_runtime(nil), do: nil

  defp format_runtime(minutes) when is_integer(minutes) and minutes > 0 do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)

    cond do
      hours > 0 and mins > 0 -> "#{hours}h #{mins}m"
      hours > 0 -> "#{hours}h"
      true -> "#{mins}m"
    end
  end

  defp format_runtime(_), do: nil

  defp format_seasons(1), do: "1 season"

  defp format_seasons(count) when is_integer(count) and count > 0 do
    "#{count} seasons"
  end

  defp format_seasons(_), do: nil
end
