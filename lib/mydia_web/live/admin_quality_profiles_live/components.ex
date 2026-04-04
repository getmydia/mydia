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
                Any Quality (first available)
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

      <div class="divider my-2"></div>

      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-sparkles" class="w-5 h-5 opacity-60" /> Quality Profiles
          <span class="badge badge-ghost">{length(@quality_profiles)}</span>
        </h2>
        <div class="flex flex-wrap gap-2">
          <button class="btn btn-sm btn-ghost" phx-click="show_browse_presets_modal">
            <.icon name="hero-sparkles" class="w-4 h-4" />
            <span class="hidden sm:inline">Browse</span> Presets
          </button>
          <button class="btn btn-sm btn-ghost" phx-click="show_import_modal">
            <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> Import
          </button>
          <button class="btn btn-sm btn-primary" phx-click="new_quality_profile">
            <.icon name="hero-plus" class="w-4 h-4" /> New
          </button>
        </div>
      </div>

      <%= if @quality_profiles == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>No quality profiles configured yet. Create one to get started.</span>
        </div>
      <% else %>
        <div class="bg-base-200 rounded-box divide-y divide-base-300">
          <%= for profile <- @quality_profiles do %>
            <% standards = profile.quality_standards || %{} %>
            <% video_codecs = get_in(standards, [:preferred_video_codecs]) || [] %>
            <% resolutions = get_in(standards, [:preferred_resolutions]) || [] %>
            <% movie_min = get_in(standards, [:movie_min_size_mb]) %>
            <% movie_max = get_in(standards, [:movie_max_size_mb]) %>
            <% episode_min = get_in(standards, [:episode_min_size_mb]) %>
            <% episode_max = get_in(standards, [:episode_max_size_mb]) %>

            <div class="p-3 sm:p-4">
              <%!-- Mobile: stacked, Desktop: flex row --%>
              <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                <%!-- Profile Info --%>
                <div class="flex-1 min-w-0">
                  <div class="font-semibold flex items-center gap-2 flex-wrap">
                    {profile.name}
                    <%= if profile.is_system do %>
                      <span class="badge badge-primary badge-xs">System</span>
                    <% end %>
                  </div>
                  <div class="text-xs opacity-60 flex flex-wrap gap-x-3 gap-y-1 mt-1">
                    <%= if video_codecs != [] do %>
                      <span>
                        <span class="font-medium">Codecs:</span>
                        {Enum.take(video_codecs, 3) |> Enum.join(", ")}
                        <%= if length(video_codecs) > 3 do %>
                          <span class="opacity-50">+{length(video_codecs) - 3}</span>
                        <% end %>
                      </span>
                    <% end %>
                    <%= if resolutions != [] do %>
                      <span>
                        <span class="font-medium">Res:</span>
                        {Enum.take(resolutions, 2) |> Enum.join(", ")}
                        <%= if length(resolutions) > 2 do %>
                          <span class="opacity-50">+{length(resolutions) - 2}</span>
                        <% end %>
                      </span>
                    <% end %>
                    <%= if movie_min || movie_max do %>
                      <span class="hidden sm:inline">
                        <span class="font-medium">Movies:</span>
                        {movie_min || "0"}-{movie_max || "∞"}MB
                      </span>
                    <% end %>
                    <%= if episode_min || episode_max do %>
                      <span class="hidden sm:inline">
                        <span class="font-medium">Episodes:</span>
                        {episode_min || "0"}-{episode_max || "∞"}MB
                      </span>
                    <% end %>
                  </div>
                </div>

                <%!-- Actions --%>
                <div class="join ml-auto sm:ml-0">
                  <button
                    class="btn btn-sm btn-ghost join-item"
                    phx-click="edit_quality_profile"
                    phx-value-id={profile.id}
                    title="Edit"
                  >
                    <.icon name="hero-pencil" class="w-4 h-4" />
                  </button>
                  <button
                    class="btn btn-sm btn-ghost join-item"
                    phx-click="duplicate_quality_profile"
                    phx-value-id={profile.id}
                    title="Duplicate"
                  >
                    <.icon name="hero-document-duplicate" class="w-4 h-4" />
                  </button>
                  <div class="dropdown dropdown-end">
                    <label tabindex="0" class="btn btn-sm btn-ghost join-item" title="Export">
                      <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                    </label>
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
                  <button
                    class="btn btn-sm btn-ghost join-item text-error"
                    phx-click="delete_quality_profile"
                    phx-value-id={profile.id}
                    title="Delete"
                  >
                    <.icon name="hero-trash" class="w-4 h-4" />
                  </button>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
