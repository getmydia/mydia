defmodule MydiaWeb.CollectionLive.PresetComponents do
  @moduledoc """
  Function components for the preset collection gallery on the collections page.

  Kept out of `MydiaWeb.CollectionComponents` (already over the size guideline)
  and out of the sibling `components.ex` (which holds the smart rules editor), so
  the gallery stays reviewable on its own.
  """
  use MydiaWeb, :html

  alias Mydia.Collections.Preset

  @doc """
  The grouped grid of preset cards.

  `counts` maps preset key to item count. A key missing from the map means the
  count has not loaded yet and the card shows a spinner instead of a number.
  `added` is the set of keys added during this gallery session. `existing_names`
  is the set of downcased collection names the user already has, used only for a
  soft hint.
  """
  attr :presets, :list, required: true
  attr :groups, :list, required: true
  attr :counts, :map, required: true
  attr :added, :any, required: true
  attr :existing_names, :any, required: true

  def preset_gallery(assigns) do
    ~H"""
    <div class="space-y-6">
      <%= for group <- @groups do %>
        <% group_presets = Enum.filter(@presets, &(&1.group == group)) %>
        <div :if={group_presets != []}>
          <h3 class="text-sm font-semibold text-base-content/70 mb-3">
            {group_label(group)}
          </h3>
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <.preset_card
              :for={preset <- group_presets}
              preset={preset}
              count={Map.get(@counts, preset.key)}
              added={MapSet.member?(@added, preset.key)}
              duplicate={MapSet.member?(@existing_names, String.downcase(preset.name))}
            />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  A single preset card.
  """
  attr :preset, Preset, required: true
  attr :count, :any, default: nil
  attr :added, :boolean, default: false
  attr :duplicate, :boolean, default: false

  def preset_card(assigns) do
    ~H"""
    <div
      id={"preset-card-#{@preset.key}"}
      class={[
        "card card-compact bg-base-200 border border-base-300 transition-all duration-200",
        @added && "opacity-60",
        !@added && "hover:border-primary/40 hover:shadow-md"
      ]}
    >
      <div class="card-body">
        <div class="flex items-start gap-3">
          <div class="flex items-center justify-center w-9 h-9 shrink-0 rounded-lg bg-primary/15">
            <.icon name={@preset.icon} class="w-5 h-5 text-primary" />
          </div>
          <div class="min-w-0 flex-1">
            <div class="font-semibold text-sm truncate">{preset_name(@preset)}</div>
            <div class="text-xs text-base-content/60 line-clamp-2">
              {preset_description(@preset)}
            </div>
          </div>
        </div>

        <div class="flex items-center justify-between gap-2 mt-2">
          <span class="badge badge-ghost badge-sm">
            <%= if is_nil(@count) do %>
              <span class="loading loading-spinner loading-xs" />
            <% else %>
              {ngettext("%{count} item", "%{count} items", @count)}
            <% end %>
          </span>

          <%= if @added do %>
            <span id={"preset-added-#{@preset.key}"} class="text-xs text-success font-medium">
              <.icon name="hero-check" class="w-4 h-4 align-text-bottom" /> {gettext("Added")}
            </span>
          <% else %>
            <button
              id={"preset-add-#{@preset.key}"}
              type="button"
              class="btn btn-primary btn-xs"
              phx-click="add_preset"
              phx-value-key={@preset.key}
            >
              {gettext("Add")}
            </button>
          <% end %>
        </div>

        <div :if={@duplicate and not @added} class="text-[11px] text-base-content/50">
          {gettext("You already have a collection with this name.")}
        </div>
      </div>
    </div>
    """
  end

  # The preset catalog (`Mydia.Collections.Presets`) carries English text, so the
  # web side translates by key. The stored collection name stays English; only
  # the gallery text changes. Unknown keys fall back to the catalog text.
  defp group_label("Decades"), do: gettext("Decades")
  defp group_label("Genres"), do: gettext("Genres")
  defp group_label("Highlights"), do: gettext("Highlights")
  defp group_label("Series"), do: gettext("Series")
  defp group_label("Language"), do: gettext("Language")
  defp group_label(group), do: group

  defp preset_name(%{key: "decade_1980s"}), do: gettext("1980s")
  defp preset_name(%{key: "decade_1990s"}), do: gettext("1990s")
  defp preset_name(%{key: "decade_2000s"}), do: gettext("2000s")
  defp preset_name(%{key: "decade_2010s"}), do: gettext("2010s")
  defp preset_name(%{key: "decade_2020s"}), do: gettext("2020s")
  defp preset_name(%{key: "genre_action"}), do: gettext("Action")
  defp preset_name(%{key: "genre_comedy"}), do: gettext("Comedy")
  defp preset_name(%{key: "genre_horror"}), do: gettext("Horror")
  defp preset_name(%{key: "genre_science_fiction"}), do: gettext("Science Fiction")
  defp preset_name(%{key: "genre_documentary"}), do: gettext("Documentary")
  defp preset_name(%{key: "genre_animation"}), do: gettext("Animation")
  defp preset_name(%{key: "highly_rated"}), do: gettext("Highly Rated")
  defp preset_name(%{key: "recently_added"}), do: gettext("Recently Added")
  defp preset_name(%{key: "ongoing_series"}), do: gettext("Ongoing Series")
  defp preset_name(%{key: "completed_series"}), do: gettext("Completed Series")
  defp preset_name(%{key: "foreign_language"}), do: gettext("Foreign Language")
  defp preset_name(preset), do: preset.name

  defp preset_description(%{key: "decade_1980s"}),
    do: gettext("Everything released between 1980 and 1989.")

  defp preset_description(%{key: "decade_1990s"}),
    do: gettext("Everything released between 1990 and 1999.")

  defp preset_description(%{key: "decade_2000s"}),
    do: gettext("Everything released between 2000 and 2009.")

  defp preset_description(%{key: "decade_2010s"}),
    do: gettext("Everything released between 2010 and 2019.")

  defp preset_description(%{key: "decade_2020s"}),
    do: gettext("Everything released between 2020 and 2029.")

  defp preset_description(%{key: "genre_action"}),
    do: gettext("Action titles from across your library.")

  defp preset_description(%{key: "genre_comedy"}),
    do: gettext("Comedies from across your library.")

  defp preset_description(%{key: "genre_horror"}),
    do: gettext("Horror titles from across your library.")

  defp preset_description(%{key: "genre_science_fiction"}),
    do: gettext("Science fiction and fantasy from across your library.")

  defp preset_description(%{key: "genre_documentary"}),
    do: gettext("Documentaries from across your library.")

  defp preset_description(%{key: "genre_animation"}),
    do: gettext("Animated titles from across your library.")

  defp preset_description(%{key: "highly_rated"}), do: gettext("Rated 8.0 or better.")

  defp preset_description(%{key: "recently_added"}),
    do: gettext("Added to your library in the last 30 days.")

  defp preset_description(%{key: "ongoing_series"}),
    do: gettext("Series that are still releasing new episodes.")

  defp preset_description(%{key: "completed_series"}),
    do: gettext("Series that have finished their run.")

  defp preset_description(%{key: "foreign_language"}),
    do: gettext("Titles whose original language is not English.")

  defp preset_description(preset), do: preset.description
end
