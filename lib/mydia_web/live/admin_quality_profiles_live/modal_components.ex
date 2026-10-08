defmodule MydiaWeb.AdminQualityProfilesLive.ModalComponents do
  @moduledoc false
  use MydiaWeb, :html

  import MydiaWeb.AdminQualityProfilesLive.CustomFormatSection
  alias MydiaWeb.AdminQualityProfilesLive.ProfileFormTabs
  alias MydiaWeb.AdminQualityProfilesLive.StandardsTab

  @doc """
  Renders the Quality Profile delete confirmation modal.

  Shows when attempting to delete a profile that is assigned to media items,
  allowing the user to force delete and unassign from all affected items.
  """
  attr :profile_to_delete, :map, required: true
  attr :affected_media_count, :integer, required: true

  def quality_profile_delete_confirm_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Delete Quality Profile?</h3>
        <p class="py-4">
          The quality profile <span class="font-semibold">{@profile_to_delete.name}</span>
          is currently assigned to media items.
        </p>
        <div class="bg-base-200 p-3 rounded-box mb-4">
          <p class="text-sm">
            <span class="font-semibold">Affected media items:</span>
            <span class="badge badge-warning badge-sm ml-2">{@affected_media_count}</span>
          </p>
        </div>
        <p class="text-warning text-sm mb-4">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" />
          Deleting this profile will unassign it from all affected media items. They will have no quality profile assigned.
        </p>
        <div class="modal-action">
          <button type="button" phx-click="cancel_delete_quality_profile" class="btn btn-ghost">
            Cancel
          </button>
          <button type="button" phx-click="confirm_delete_quality_profile" class="btn btn-error">
            Delete Anyway
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="cancel_delete_quality_profile"></div>
    </div>
    """
  end

  @doc """
  Renders the Quality Profile modal.
  """
  attr :quality_profile_form, :any, required: true
  attr :quality_profile_mode, :atom, required: true
  attr :quality_profile_active_tab, :string, required: true
  attr :custom_formats, :list, required: true
  attr :custom_format_assignments, :map, required: true

  def quality_profile_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-5xl">
        <h3 class="font-bold text-lg mb-4">
          {if @quality_profile_mode == :new,
            do: "New Quality Profile",
            else: "Edit Quality Profile"}
        </h3>

        <%!-- Tab Navigation --%>
        <div role="tablist" class="tabs tabs-bordered mb-6">
          <button
            type="button"
            role="tab"
            class={["tab", @quality_profile_active_tab == "basic" && "tab-active"]}
            phx-click="change_quality_profile_tab"
            phx-value-tab="basic"
          >
            Basic Info
          </button>
          <button
            type="button"
            role="tab"
            class={["tab", @quality_profile_active_tab == "standards" && "tab-active"]}
            phx-click="change_quality_profile_tab"
            phx-value-tab="standards"
          >
            Quality Standards
          </button>
          <button
            type="button"
            role="tab"
            class={["tab", @quality_profile_active_tab == "exclude" && "tab-active"]}
            phx-click="change_quality_profile_tab"
            phx-value-tab="exclude"
          >
            Exclude
          </button>
        </div>

        <.form
          for={@quality_profile_form}
          id="quality-profile-form"
          phx-change="validate_quality_profile"
          phx-submit="save_quality_profile"
        >
          <%!-- Basic Info Tab - Always rendered, hidden when not active --%>
          <div class={if @quality_profile_active_tab != "basic", do: "hidden"}>
            <ProfileFormTabs.quality_profile_basic_tab form={@quality_profile_form} />
          </div>

          <%!-- Quality Standards Tab - Always rendered, hidden when not active --%>
          <div class={if @quality_profile_active_tab != "standards", do: "hidden"}>
            <StandardsTab.quality_profile_standards_tab form={@quality_profile_form} />
            <.custom_format_section
              formats={@custom_formats}
              assignments={@custom_format_assignments}
            />
          </div>

          <%!-- Exclude Tab - Always rendered, hidden when not active --%>
          <div class={if @quality_profile_active_tab != "exclude", do: "hidden"}>
            <ProfileFormTabs.quality_profile_exclude_tab form={@quality_profile_form} />
          </div>

          <div class="modal-action">
            <button type="button" class="btn" phx-click="close_quality_profile_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">Save Profile</button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  @doc """
  Renders the Import Quality Profile modal.
  """
  attr :import_error, :string, default: nil

  def import_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">Import Quality Profile</h3>

        <div class="space-y-4">
          <div class="alert alert-info">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <span class="text-sm">
              Import a quality profile from a remote URL. Supports both JSON and YAML formats.
            </span>
          </div>

          <.form for={%{}} id="import-profile-form" phx-submit="import_quality_profile_url">
            <div class="form-control">
              <label class="label">
                <span class="label-text font-semibold">Profile URL</span>
              </label>
              <input
                type="url"
                name="url"
                placeholder="https://example.com/my-quality-profile.json"
                required
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt text-xs">
                  Enter the URL of a JSON or YAML quality profile
                </span>
              </label>
            </div>

            <%= if @import_error do %>
              <div class="alert alert-error mt-4">
                <.icon name="hero-exclamation-circle" class="w-5 h-5" />
                <span class="text-sm">{@import_error}</span>
              </div>
            <% end %>

            <div class="modal-action">
              <button type="button" class="btn" phx-click="close_import_modal">
                Cancel
              </button>
              <button type="submit" class="btn btn-primary">
                <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> Import
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
