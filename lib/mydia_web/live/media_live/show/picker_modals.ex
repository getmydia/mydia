defmodule MydiaWeb.MediaLive.Show.PickerModals do
  @moduledoc """
  Page-level picker modals opened from the media show page's hero column: quality
  profile, download library and collection.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext
  use MydiaWeb, :verified_routes
  import MydiaWeb.CoreComponents

  alias Mydia.Settings.LibraryPath

  @doc """
  Quality profile picker, opened from the hero column's Quality Profile row.

  A page-level modal rather than an anchored dropdown: the row lives inside
  the hero column's `overflow-y-auto` wrapper
  (`MydiaWeb.MediaLive.Show.Components.hero_section/1`), which clips an
  anchored daisyUI dropdown's menu once it runs past the column's remaining
  headroom, exactly the failure mode issue #465 already fixed once for a
  different surface. Confirmed by measuring the real page, not assumed from
  the CSS alone.
  """
  attr :media_item, :map, required: true
  attr :quality_profiles, :list, required: true
  attr :default_quality_profile_name, :string, default: nil

  def quality_profile_modal(assigns) do
    ~H"""
    <div id="quality-profile-modal" class="modal modal-open">
      <div class="modal-box max-w-sm">
        <h3 class="font-bold text-lg mb-2">{gettext("Quality Profile")}</h3>
        <ul class="menu w-full p-0">
          <li>
            <button
              type="button"
              phx-click="update_quality_profile"
              phx-value-profile-id=""
              class={[
                "justify-between",
                is_nil(@media_item.quality_profile_id) && "active"
              ]}
            >
              {default_quality_profile_label(@default_quality_profile_name)}
              <.icon
                :if={is_nil(@media_item.quality_profile_id)}
                name="hero-check"
                class="w-4 h-4"
              />
            </button>
          </li>
          <li :for={profile <- @quality_profiles}>
            <button
              type="button"
              phx-click="update_quality_profile"
              phx-value-profile-id={profile.id}
              class={[
                "justify-between",
                @media_item.quality_profile_id == profile.id && "active"
              ]}
            >
              {profile.name}
              <.icon
                :if={@media_item.quality_profile_id == profile.id}
                name="hero-check"
                class="w-4 h-4"
              />
            </button>
          </li>
        </ul>
        <div class="modal-action">
          <button type="button" phx-click="hide_quality_profile_modal" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_quality_profile_modal"></div>
    </div>
    """
  end

  # Label for the blank quality-profile choice.
  #
  # That choice stores `nil`, which means "follow the configured default"
  # (`Mydia.Indexers.QualityProfileResolver`). When no default is configured,
  # `nil` genuinely means no profile, and the label says so.
  @spec default_quality_profile_label(String.t() | nil) :: String.t()
  defp default_quality_profile_label(nil), do: gettext("No profile")

  defp default_quality_profile_label(name) when is_binary(name),
    do: gettext("Use default (%{name})", name: name)

  @doc """
  Target library picker, opened from the hero column's Library row.

  Same page-level-modal reasoning as `quality_profile_modal/1` above: see
  `MydiaWeb.MediaLive.Show.LibraryComponents.target_library_row/1` for the
  full rationale.
  """
  attr :media_item, :map, required: true
  attr :libraries, :list, default: []

  def target_library_modal(assigns) do
    assigns = assign(assigns, :labels, LibraryPath.display_names(assigns.libraries))

    ~H"""
    <div id="target-library-modal" class="modal modal-open">
      <div class="modal-box max-w-sm">
        <h3 class="font-bold text-lg mb-2">{gettext("Download Library")}</h3>
        <ul class="menu w-full p-0">
          <li>
            <button
              type="button"
              phx-click="update_target_library"
              phx-value-library-path-id=""
              class={["justify-between", is_nil(@media_item.library_path_id) && "active"]}
            >
              {gettext("Automatic")}
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
              {@labels[library.id]}
              <.icon
                :if={@media_item.library_path_id == library.id}
                name="hero-check"
                class="w-4 h-4"
              />
            </button>
          </li>
        </ul>
        <p class="text-xs text-base-content/60 mt-3">
          {gettext(
            "Changing this affects future downloads. Files already on disk stay where they are."
          )}
        </p>
        <div class="modal-action">
          <button type="button" phx-click="hide_target_library_modal" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_target_library_modal"></div>
    </div>
    """
  end

  @doc """
  Add-to-collection picker, opened from the hero column's Collection button.

  Same page-level-modal reasoning as `quality_profile_modal/1` above.
  """
  attr :media_item, :map, required: true
  attr :user_collections, :list, default: []
  attr :item_collections, :list, default: []

  def add_to_collection_modal(assigns) do
    ~H"""
    <div id="add-to-collection-modal" class="modal modal-open">
      <div class="modal-box max-w-sm">
        <h3 class="font-bold text-lg mb-2">{gettext("Add to Collection")}</h3>
        <%= if Enum.empty?(@user_collections) do %>
          <p class="text-sm text-base-content/60 mb-3">{gettext("No collections yet.")}</p>
          <.link navigate={~p"/collections"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Create Collection")}
          </.link>
        <% else %>
          <ul class="menu w-full p-0">
            <li :for={collection <- @user_collections}>
              <% is_in_collection = Enum.any?(@item_collections, &(&1.id == collection.id)) %>
              <button
                type="button"
                phx-click={
                  if is_in_collection, do: "remove_from_collection", else: "add_to_collection"
                }
                phx-value-collection-id={collection.id}
                class="justify-between"
              >
                <span class="flex items-center gap-2">
                  <.icon
                    name={if collection.is_system, do: "hero-star", else: "hero-folder"}
                    class="w-4 h-4"
                  />
                  {collection.name}
                </span>
                <.icon :if={is_in_collection} name="hero-check" class="w-4 h-4 text-success" />
              </button>
            </li>
          </ul>
          <.link navigate={~p"/collections"} class="btn btn-ghost btn-sm mt-2">
            <.icon name="hero-folder-open" class="w-4 h-4" /> {gettext("Manage Collections")}
          </.link>
        <% end %>
        <div class="modal-action">
          <button type="button" phx-click="close_add_to_collection_modal" class="btn btn-ghost">
            {gettext("Close")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_add_to_collection_modal"></div>
    </div>
    """
  end
end
