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
          <h3 class="text-sm font-semibold text-base-content/70 mb-3">{group}</h3>
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
            <div class="font-semibold text-sm truncate">{@preset.name}</div>
            <div class="text-xs text-base-content/60 line-clamp-2">{@preset.description}</div>
          </div>
        </div>

        <div class="flex items-center justify-between gap-2 mt-2">
          <span class="badge badge-ghost badge-sm">
            <%= if is_nil(@count) do %>
              <span class="loading loading-spinner loading-xs" />
            <% else %>
              {@count} {if @count == 1, do: "item", else: "items"}
            <% end %>
          </span>

          <%= if @added do %>
            <span id={"preset-added-#{@preset.key}"} class="text-xs text-success font-medium">
              <.icon name="hero-check" class="w-4 h-4 align-text-bottom" /> Added
            </span>
          <% else %>
            <button
              id={"preset-add-#{@preset.key}"}
              type="button"
              class="btn btn-primary btn-xs"
              phx-click="add_preset"
              phx-value-key={@preset.key}
            >
              Add
            </button>
          <% end %>
        </div>

        <div :if={@duplicate and not @added} class="text-[11px] text-base-content/50">
          You already have a collection with this name.
        </div>
      </div>
    </div>
    """
  end
end
