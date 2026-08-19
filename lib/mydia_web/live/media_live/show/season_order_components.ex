defmodule MydiaWeb.MediaLive.Show.SeasonOrderComponents do
  @moduledoc """
  The TV show page's season-ordering controls: the persistent selector and the
  dismissible suggestion banner.

  Split out of `MydiaWeb.MediaLive.Show.SeasonComponents`, which had grown past
  the project's ~500 LOC component guideline. The two share a page but not a
  subject: this one is about which of TVDB's parallel orderings the show is in,
  its sibling about rendering whichever one that turns out to be.
  """

  use MydiaWeb, :html

  import MydiaWeb.MediaLive.Show.Formatters

  alias Mydia.Media.SeasonOrder

  @doc """
  Season-ordering controls for a TVDB-sourced TV show: a persistent selector
  (any TVDB show, any time) and a dismissible suggestion banner (only when
  the show has never been asked and its official season looks wrong).

  Absent entirely for non-TVDB shows — there is nothing to switch between —
  and for a viewer who cannot update media, since `change_season_order` is
  authorization-gated: showing a control that will be refused is worse than
  not showing it.
  """
  attr :media_item, :map, required: true
  attr :season_order_suggestion, :any, default: nil
  attr :can_update_media, :boolean, required: true

  def season_order_controls(assigns) do
    ~H"""
    <div :if={tvdb_show?(@media_item) and @can_update_media} class="mb-4 space-y-3">
      <div
        :if={@season_order_suggestion}
        id="season-order-suggestion"
        class="alert alert-info items-start"
      >
        <.icon name="hero-information-circle" class="w-5 h-5 shrink-0 mt-0.5" />
        <div class="flex-1">
          <p class="text-sm">
            One season here has {season_episode_max(@media_item)} episodes. TVDB also splits
            this show into {format_season_ordering_counts(@season_order_suggestion.counts)} as a DVD ordering.
          </p>
          <div class="flex gap-2 mt-2">
            <button
              type="button"
              id="season-order-accept"
              class="btn btn-sm btn-primary"
              phx-click="change_season_order"
              phx-value-order="dvd"
            >
              Use DVD ordering
            </button>
            <button
              type="button"
              id="season-order-dismiss"
              class="btn btn-sm btn-ghost"
              phx-click="change_season_order"
              phx-value-order="official"
            >
              Keep aired order
            </button>
          </div>
        </div>
      </div>

      <form
        id="season-order-form"
        phx-change="change_season_order"
        class="flex items-center gap-2"
      >
        <label for="season-order-select" class="text-xs text-base-content/60">
          Episode ordering
        </label>
        <select id="season-order-select" name="order" class="select select-xs select-bordered w-auto">
          <option
            :for={order <- SeasonOrder.values()}
            value={order}
            selected={current_season_order(@media_item) == order}
          >
            {SeasonOrder.label(order)}
          </option>
        </select>
      </form>
    </div>
    """
  end

  defp tvdb_show?(media_item),
    do: media_item.type == "tv_show" and media_item.metadata_source == :tvdb

  defp current_season_order(media_item), do: SeasonOrder.effective(media_item)

  defp season_episode_max(media_item) do
    media_item.episodes
    |> Enum.group_by(& &1.season_number)
    |> Enum.map(fn {_season_number, eps} -> length(eps) end)
    |> Enum.max(fn -> 0 end)
  end
end
