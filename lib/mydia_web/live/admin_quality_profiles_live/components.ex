defmodule MydiaWeb.AdminQualityProfilesLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  Renders the Quality Profiles tab content.
  """
  attr :quality_profiles, :list, required: true
  attr :default_quality_profile_id, :string, default: nil

  def quality_profiles_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4" phx-hook="DownloadFile" id="quality-profiles-section">
      <%!-- Default Quality Profile Setting --%>
      <div class="bg-base-200 rounded-box p-4">
        <div class="flex flex-col sm:flex-row sm:items-center gap-3">
          <div class="flex-1">
            <div class="font-medium">Default Quality Profile</div>
            <div class="text-xs opacity-60">
              Used when adding new media items to your library
            </div>
          </div>
          <form phx-change="update_default_quality_profile" id="default-quality-profile-form">
            <select
              id="default-quality-profile-select"
              class="select select-sm select-bordered w-full sm:w-64"
              name="profile_id"
            >
              <option value="" selected={is_nil(@default_quality_profile_id)}>
                None (no default)
              </option>
              <%= for profile <- @quality_profiles do %>
                <option value={profile.id} selected={@default_quality_profile_id == profile.id}>
                  {profile.name}
                </option>
              <% end %>
            </select>
          </form>
        </div>
      </div>

      <.admin_list id="quality-profiles" items={@quality_profiles}>
        <:empty>No quality profiles configured yet. Create one to get started.</:empty>
        <:row :let={profile}>
          <% standards = profile.quality_standards || %{} %>
          <% video_codecs = get_in(standards, [:preferred_video_codecs]) || [] %>
          <% resolutions = get_in(standards, [:preferred_resolutions]) || [] %>
          <% movie_min = get_in(standards, [:movie_min_size_mb]) %>
          <% movie_max = get_in(standards, [:movie_max_size_mb]) %>
          <% episode_min = get_in(standards, [:episode_min_size_mb]) %>
          <% episode_max = get_in(standards, [:episode_max_size_mb]) %>
          <.admin_row id={"quality-profile-#{profile.id}"}>
            <:title>
              {profile.name}
              <span :if={profile.is_system} class="badge badge-sm badge-outline">System</span>
            </:title>
            <:descriptor>
              <span :if={video_codecs != []} class="mr-3">
                <span class="font-medium">Codecs:</span>
                {Enum.take(video_codecs, 3) |> Enum.join(", ")}
                <span :if={length(video_codecs) > 3} class="opacity-50">
                  +{length(video_codecs) - 3}
                </span>
              </span>
              <span :if={resolutions != []} class="mr-3">
                <span class="font-medium">Res:</span>
                {Enum.take(resolutions, 2) |> Enum.join(", ")}
                <span :if={length(resolutions) > 2} class="opacity-50">
                  +{length(resolutions) - 2}
                </span>
              </span>
              <span :if={movie_min || movie_max} class="hidden sm:inline mr-3">
                <span class="font-medium">Movies:</span>
                {movie_min || "0"}-{movie_max || "∞"}MB
              </span>
              <span :if={episode_min || episode_max} class="hidden sm:inline">
                <span class="font-medium">Episodes:</span>
                {episode_min || "0"}-{episode_max || "∞"}MB
              </span>
            </:descriptor>
            <:actions>
              <div class="flex items-center gap-2 ml-auto sm:ml-2">
                <.row_actions>
                  <.row_action
                    id={"edit-quality-profile-#{profile.id}"}
                    icon="hero-pencil"
                    title="Edit"
                    phx-click="edit_quality_profile"
                    phx-value-id={profile.id}
                  />
                  <.row_action
                    id={"duplicate-quality-profile-#{profile.id}"}
                    icon="hero-document-duplicate"
                    title="Duplicate"
                    phx-click="duplicate_quality_profile"
                    phx-value-id={profile.id}
                  />
                  <.row_action
                    id={"delete-quality-profile-#{profile.id}"}
                    icon="hero-trash"
                    title="Delete"
                    destructive
                    phx-click="delete_quality_profile"
                    phx-value-id={profile.id}
                  />
                </.row_actions>
                <div class="dropdown dropdown-end">
                  <div
                    tabindex="0"
                    role="button"
                    id={"export-quality-profile-#{profile.id}"}
                    class="btn btn-sm btn-ghost"
                    title="Export"
                    aria-label="Export"
                  >
                    <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                  </div>
                  <ul
                    tabindex="0"
                    class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-32"
                  >
                    <li>
                      <button
                        phx-click="export_quality_profile"
                        phx-value-id={profile.id}
                        phx-value-format="json"
                      >
                        JSON
                      </button>
                    </li>
                    <li>
                      <button
                        phx-click="export_quality_profile"
                        phx-value-id={profile.id}
                        phx-value-format="yaml"
                      >
                        YAML
                      </button>
                    </li>
                  </ul>
                </div>
              </div>
            </:actions>
          </.admin_row>
        </:row>
      </.admin_list>
    </div>
    """
  end

  @doc "The page header's preset, import and New buttons."
  def header_actions(assigns) do
    ~H"""
    <button class="btn btn-sm btn-ghost" phx-click="open_quality_profile_presets_modal">
      <.icon name="hero-sparkles" class="w-4 h-4" />
      <span class="hidden sm:inline">Browse</span> Presets
    </button>
    <button class="btn btn-sm btn-ghost" phx-click="open_import_quality_profile_modal">
      <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> Import
    </button>
    <button class="btn btn-sm btn-primary" phx-click="new_quality_profile">
      <.icon name="hero-plus" class="w-4 h-4" /> New
    </button>
    """
  end
end
