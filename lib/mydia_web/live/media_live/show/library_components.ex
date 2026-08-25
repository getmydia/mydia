defmodule MydiaWeb.MediaLive.Show.LibraryComponents do
  @moduledoc """
  The target-library row in the media detail hero.

  Shows where this item's next download will land and why. The reason is what
  makes a surprising destination debuggable rather than merely surprising.
  """

  use MydiaWeb, :html

  @doc """
  Renders the resolved target library.

  With two or more candidates this is a button opening a page-level picker
  modal (`MydiaWeb.MediaLive.Show.Modals.target_library_modal/1`) that writes
  `media_items.library_path_id`; with one it is static text. Selecting
  "Automatic" clears the column and returns the item to dynamic resolution.

  This used to be an anchored daisyUI dropdown, but this row lives inside the
  hero column's `overflow-y-auto` wrapper (see the note at the top of
  `MydiaWeb.MediaLive.Show.Components.hero_section/1`), and a
  `.dropdown-content` menu gets clipped by that ancestor's overflow box the
  moment it runs past the column's remaining headroom, exactly the failure
  mode issue #465 already fixed once for a different surface. Confirmed by
  measuring the real page with a realistic library count, not assumed from
  the CSS alone.
  """
  attr :media_item, :map, required: true
  attr :target_library, :map, default: nil
  attr :target_reason, :atom, default: nil
  attr :libraries, :list, default: []

  def target_library_row(assigns) do
    ~H"""
    <%= if length(@libraries) > 1 do %>
      <button
        type="button"
        phx-click="show_target_library_modal"
        data-test="target-library"
        class="flex items-center gap-2.5 px-2 py-1.5 rounded-lg w-full group transition-colors cursor-pointer hover:bg-base-300/50"
        title="Click to change the download library"
      >
        <.target_library_row_content
          target_library={@target_library}
          target_reason={@target_reason}
          interactive?={true}
        />
      </button>
    <% else %>
      <div
        data-test="target-library"
        class="flex items-center gap-2.5 px-2 py-1.5 rounded-lg w-full group transition-colors"
      >
        <.target_library_row_content
          target_library={@target_library}
          target_reason={@target_reason}
          interactive?={false}
        />
      </div>
    <% end %>
    """
  end

  attr :target_library, :map, default: nil
  attr :target_reason, :atom, default: nil
  attr :interactive?, :boolean, required: true

  defp target_library_row_content(assigns) do
    ~H"""
    <div class="w-8 h-8 rounded-lg bg-accent/10 flex items-center justify-center flex-shrink-0">
      <.icon name="hero-folder" class="w-4 h-4 text-accent" />
    </div>
    <div class="flex-1 min-w-0 text-left">
      <div class="text-xs text-base-content/50">Library</div>
      <div class="text-sm font-medium truncate">
        <%= if @target_library do %>
          {Path.basename(@target_library.path)}
          <span class="text-xs font-normal text-base-content/50">
            {reason_label(@target_reason)}
          </span>
        <% else %>
          <span class="text-base-content/40">No compatible library</span>
        <% end %>
      </div>
    </div>
    <.icon
      :if={@interactive?}
      name="hero-chevron-right"
      class="w-4 h-4 text-base-content/30 group-hover:text-base-content/60 transition-colors flex-shrink-0"
    />
    """
  end

  defp reason_label(:download_override), do: "set on the download"
  defp reason_label(:explicit), do: "chosen"
  defp reason_label(:existing_files), do: "matches existing files"
  defp reason_label(:type_default), do: "library default"
  defp reason_label(:first_compatible), do: "first compatible library"
  defp reason_label(_), do: ""
end
