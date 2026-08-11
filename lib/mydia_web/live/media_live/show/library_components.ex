defmodule MydiaWeb.MediaLive.Show.LibraryComponents do
  @moduledoc """
  The target-library row in the media detail hero.

  Shows where this item's next download will land and why. The reason is what
  makes a surprising destination debuggable rather than merely surprising.
  """

  use MydiaWeb, :html

  @doc """
  Renders the resolved target library.

  With two or more candidates this is a dropdown writing
  `media_items.library_path_id`; with one it is static text. Selecting
  "Automatic" clears the column and returns the item to dynamic resolution.
  """
  attr :media_item, :map, required: true
  attr :target_library, :map, default: nil
  attr :target_reason, :atom, default: nil
  attr :libraries, :list, default: []

  def target_library_row(assigns) do
    ~H"""
    <div class="dropdown dropdown-end w-full" data-test="target-library">
      <div
        tabindex="0"
        role={if length(@libraries) > 1, do: "button", else: nil}
        class={[
          "flex items-center gap-2.5 px-2 py-1.5 rounded-lg w-full group transition-colors",
          length(@libraries) > 1 && "cursor-pointer hover:bg-base-300/50"
        ]}
        title={if length(@libraries) > 1, do: "Click to change the download library", else: nil}
      >
        <div class="w-8 h-8 rounded-lg bg-accent/10 flex items-center justify-center flex-shrink-0">
          <.icon name="hero-folder" class="w-4 h-4 text-accent" />
        </div>
        <div class="flex-1 min-w-0">
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
          :if={length(@libraries) > 1}
          name="hero-chevron-right"
          class="w-4 h-4 text-base-content/30 group-hover:text-base-content/60 transition-colors flex-shrink-0"
        />
      </div>
      <ul
        :if={length(@libraries) > 1}
        tabindex="0"
        class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-64 border border-base-300"
      >
        <li>
          <button
            type="button"
            phx-click="update_target_library"
            phx-value-library-path-id=""
            class={["justify-between", is_nil(@media_item.library_path_id) && "active"]}
          >
            Automatic
            <.icon :if={is_nil(@media_item.library_path_id)} name="hero-check" class="w-4 h-4" />
          </button>
        </li>
        <li :for={library <- @libraries}>
          <button
            type="button"
            phx-click="update_target_library"
            phx-value-library-path-id={library.id}
            class={["justify-between", @media_item.library_path_id == library.id && "active"]}
          >
            {Path.basename(library.path)}
            <.icon
              :if={@media_item.library_path_id == library.id}
              name="hero-check"
              class="w-4 h-4"
            />
          </button>
        </li>
        <li class="menu-title text-xs pt-2">
          Changing this affects future downloads. Files already on disk stay where they are.
        </li>
      </ul>
    </div>
    """
  end

  defp reason_label(:download_override), do: "set on the download"
  defp reason_label(:explicit), do: "chosen"
  defp reason_label(:existing_files), do: "matches existing files"
  defp reason_label(:type_default), do: "library default"
  defp reason_label(:first_compatible), do: "first compatible library"
  defp reason_label(_), do: ""
end
