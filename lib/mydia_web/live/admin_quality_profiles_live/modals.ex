defmodule MydiaWeb.AdminQualityProfilesLive.Modals do
  @moduledoc """
  Modal components for the Quality Profiles admin page.

  Extracted from Components to keep file sizes manageable.
  """
  use MydiaWeb, :html

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
        </div>

        <.form
          for={@quality_profile_form}
          id="quality-profile-form"
          phx-change="validate_quality_profile"
          phx-submit="save_quality_profile"
        >
          <%!-- Basic Info Tab - Always rendered, hidden when not active --%>
          <div class={if @quality_profile_active_tab != "basic", do: "hidden"}>
            <.quality_profile_basic_tab form={@quality_profile_form} />
          </div>

          <%!-- Quality Standards Tab - Always rendered, hidden when not active --%>
          <div class={if @quality_profile_active_tab != "standards", do: "hidden"}>
            <.quality_profile_standards_tab form={@quality_profile_form} />
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
  Renders the Basic Info tab content for the Quality Profile modal.
  """
  attr :form, :any, required: true

  def quality_profile_basic_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- System Profile Indicator --%>
      <%= if Ecto.Changeset.get_field(@form.source, :is_system, false) do %>
        <div class="alert alert-warning">
          <.icon name="hero-lock-closed" class="w-5 h-5" />
          <div>
            <div class="font-semibold">System Profile</div>
            <div class="text-sm">
              This is a built-in system profile. Some fields may be restricted.
            </div>
          </div>
        </div>
      <% end %>

      <.input field={@form[:name]} type="text" label="Name" required />

      <.input
        field={@form[:description]}
        type="textarea"
        label="Description"
        rows="3"
      />

      <%!-- Allowed Qualities --%>
      <div class="form-control">
        <label class="label">
          <span class="label-text">
            Allowed Qualities <span class="text-error">*</span>
          </span>
        </label>
        <div class="grid grid-cols-3 gap-2">
          <%= for quality <- ["360p", "480p", "576p", "720p", "1080p", "2160p", "4320p"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[qualities][]"
                value={quality}
                checked={quality in (Ecto.Changeset.get_field(@form.source, :qualities) || [])}
                class="checkbox checkbox-sm"
              />
              <span class="label-text">{quality}</span>
            </label>
          <% end %>
        </div>
        <%= if @form.errors[:qualities] do %>
          <label class="label">
            <span class="label-text-alt text-error">
              {translate_error(@form.errors[:qualities])}
            </span>
          </label>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders the Quality Standards tab content for the Quality Profile modal.
  """
  attr :form, :any, required: true

  def quality_profile_standards_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="alert alert-info">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <span class="text-sm">
          Configure quality standards including codecs, bitrates, resolutions, and file sizes. Leave fields empty to allow any value.
        </span>
      </div>

      <%!-- Video Codecs --%>
      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred Video Codecs</span>
          <span class="label-text-alt text-xs">In priority order</span>
        </label>
        <div class="grid grid-cols-3 md:grid-cols-5 gap-2">
          <%= for codec <- ["h265", "h264", "av1", "hevc", "x264", "x265", "vc1", "mpeg2", "xvid", "divx"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][preferred_video_codecs][]"
                value={codec}
                checked={
                  codec in (get_in(
                              Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                              [:preferred_video_codecs]
                            ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{codec}</span>
            </label>
          <% end %>
        </div>
      </div>

      <%!-- Audio Settings --%>
      <div class="divider">Audio Settings</div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred Audio Codecs</span>
        </label>
        <div class="grid grid-cols-3 md:grid-cols-5 gap-2">
          <%= for codec <- ["aac", "ac3", "eac3", "dts", "dts-hd", "truehd", "atmos", "flac", "mp3", "opus"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][preferred_audio_codecs][]"
                value={codec}
                checked={
                  codec in (get_in(
                              Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                              [:preferred_audio_codecs]
                            ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{codec}</span>
            </label>
          <% end %>
        </div>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred Audio Channels</span>
        </label>
        <div class="grid grid-cols-3 md:grid-cols-4 gap-2">
          <%= for channels <- ["1.0", "2.0", "2.1", "5.1", "6.1", "7.1", "7.1.2", "7.1.4"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][preferred_audio_channels][]"
                value={channels}
                checked={
                  channels in (get_in(
                                 Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                                 [:preferred_audio_channels]
                               ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{channels}</span>
            </label>
          <% end %>
        </div>
      </div>

      <%!-- Resolution Settings --%>
      <div class="divider">Resolution Settings</div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label">
            <span class="label-text">Minimum Resolution</span>
          </label>
          <select
            name="quality_profile[quality_standards][min_resolution]"
            class="select select-bordered w-full"
          >
            <option value="">No minimum</option>
            <%= for res <- ["360p", "480p", "576p", "720p", "1080p", "2160p", "4320p"] do %>
              <option
                value={res}
                selected={
                  res ==
                    get_in(
                      Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                      [:min_resolution]
                    )
                }
              >
                {res}
              </option>
            <% end %>
          </select>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">Maximum Resolution</span>
          </label>
          <select
            name="quality_profile[quality_standards][max_resolution]"
            class="select select-bordered w-full"
          >
            <option value="">No maximum</option>
            <%= for res <- ["360p", "480p", "576p", "720p", "1080p", "2160p", "4320p"] do %>
              <option
                value={res}
                selected={
                  res ==
                    get_in(
                      Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                      [:max_resolution]
                    )
                }
              >
                {res}
              </option>
            <% end %>
          </select>
        </div>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred Resolutions</span>
        </label>
        <div class="grid grid-cols-3 md:grid-cols-4 gap-2">
          <%= for res <- ["360p", "480p", "576p", "720p", "1080p", "2160p", "4320p"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][preferred_resolutions][]"
                value={res}
                checked={
                  res in (get_in(
                            Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                            [:preferred_resolutions]
                          ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{res}</span>
            </label>
          <% end %>
        </div>
      </div>

      <%!-- Source Preferences --%>
      <div class="divider">Source Preferences</div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred Sources</span>
          <span class="label-text-alt text-xs">In priority order</span>
        </label>
        <div class="grid grid-cols-2 md:grid-cols-3 gap-2">
          <%= for source <- ["BluRay", "REMUX", "WEB-DL", "WEBRip", "HDTV", "SDTV", "DVD", "DVDRip", "BDRip"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][preferred_sources][]"
                value={source}
                checked={
                  source in (get_in(
                               Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                               [:preferred_sources]
                             ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{source}</span>
            </label>
          <% end %>
        </div>
      </div>

      <%!-- Bitrate Ranges --%>
      <div class="divider">Bitrate Ranges</div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Video Bitrate (Mbps)</span>
        </label>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <input
              type="number"
              name="quality_profile[quality_standards][min_video_bitrate_mbps]"
              placeholder="Min"
              step="0.1"
              min="0"
              value={
                get_in(
                  Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                  [:min_video_bitrate_mbps]
                )
              }
              class="input input-bordered w-full"
            />
            <label class="label">
              <span class="label-text-alt">Minimum</span>
            </label>
          </div>
          <div>
            <input
              type="number"
              name="quality_profile[quality_standards][max_video_bitrate_mbps]"
              placeholder="Max"
              step="0.1"
              min="0"
              value={
                get_in(
                  Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                  [:max_video_bitrate_mbps]
                )
              }
              class="input input-bordered w-full"
            />
            <label class="label">
              <span class="label-text-alt">Maximum</span>
            </label>
          </div>
          <div>
            <input
              type="number"
              name="quality_profile[quality_standards][preferred_video_bitrate_mbps]"
              placeholder="Preferred"
              step="0.1"
              min="0"
              value={
                get_in(
                  Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                  [:preferred_video_bitrate_mbps]
                )
              }
              class="input input-bordered w-full"
            />
            <label class="label">
              <span class="label-text-alt">Preferred</span>
            </label>
          </div>
        </div>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Audio Bitrate (kbps)</span>
        </label>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <input
              type="number"
              name="quality_profile[quality_standards][min_audio_bitrate_kbps]"
              placeholder="Min"
              step="1"
              min="0"
              value={
                get_in(
                  Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                  [:min_audio_bitrate_kbps]
                )
              }
              class="input input-bordered w-full"
            />
            <label class="label">
              <span class="label-text-alt">Minimum</span>
            </label>
          </div>
          <div>
            <input
              type="number"
              name="quality_profile[quality_standards][max_audio_bitrate_kbps]"
              placeholder="Max"
              step="1"
              min="0"
              value={
                get_in(
                  Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                  [:max_audio_bitrate_kbps]
                )
              }
              class="input input-bordered w-full"
            />
            <label class="label">
              <span class="label-text-alt">Maximum</span>
            </label>
          </div>
          <div>
            <input
              type="number"
              name="quality_profile[quality_standards][preferred_audio_bitrate_kbps]"
              placeholder="Preferred"
              step="1"
              min="0"
              value={
                get_in(
                  Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                  [:preferred_audio_bitrate_kbps]
                )
              }
              class="input input-bordered w-full"
            />
            <label class="label">
              <span class="label-text-alt">Preferred</span>
            </label>
          </div>
        </div>
      </div>

      <%!-- File Size Constraints --%>
      <div class="divider">File Size Constraints (MB)</div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div class="form-control">
          <label class="label">
            <span class="label-text font-semibold">Movie File Sizes</span>
          </label>
          <div class="space-y-2">
            <div>
              <input
                type="number"
                name="quality_profile[quality_standards][movie_min_size_mb]"
                placeholder="Min size (MB)"
                step="1"
                min="0"
                value={
                  get_in(
                    Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                    [:movie_min_size_mb]
                  )
                }
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Minimum</span>
              </label>
            </div>
            <div>
              <input
                type="number"
                name="quality_profile[quality_standards][movie_max_size_mb]"
                placeholder="Max size (MB)"
                step="1"
                min="0"
                value={
                  get_in(
                    Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                    [:movie_max_size_mb]
                  )
                }
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Maximum</span>
              </label>
            </div>
          </div>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text font-semibold">Episode File Sizes</span>
          </label>
          <div class="space-y-2">
            <div>
              <input
                type="number"
                name="quality_profile[quality_standards][episode_min_size_mb]"
                placeholder="Min size (MB)"
                step="1"
                min="0"
                value={
                  get_in(
                    Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                    [:episode_min_size_mb]
                  )
                }
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Minimum</span>
              </label>
            </div>
            <div>
              <input
                type="number"
                name="quality_profile[quality_standards][episode_max_size_mb]"
                placeholder="Max size (MB)"
                step="1"
                min="0"
                value={
                  get_in(
                    Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                    [:episode_max_size_mb]
                  )
                }
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Maximum</span>
              </label>
            </div>
          </div>
        </div>
      </div>

      <%!-- HDR/Dolby Vision --%>
      <div class="divider">HDR/Dolby Vision</div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred HDR Formats</span>
        </label>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
          <%= for format <- ["hdr10", "hdr10+", "dolby_vision", "hlg"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][hdr_formats][]"
                value={format}
                checked={
                  format in (get_in(
                               Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                               [:hdr_formats]
                             ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{String.upcase(format)}</span>
            </label>
          <% end %>
        </div>
      </div>

      <div class="form-control">
        <label class="label cursor-pointer justify-start gap-3">
          <input
            type="checkbox"
            name="quality_profile[quality_standards][require_hdr]"
            value="true"
            checked={
              get_in(
                Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                [:require_hdr]
              ) == true
            }
            class="checkbox checkbox-primary"
          />
          <div>
            <span class="label-text font-semibold">Require HDR</span>
            <p class="text-xs text-base-content/70">
              Only accept files with HDR support
            </p>
          </div>
        </label>
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

  @doc """
  Renders the Browse Presets modal for quality profiles.
  """
  attr :presets, :list, required: true
  attr :selected_category, :atom, default: :all

  def browse_presets_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-6xl max-h-[90vh] flex flex-col">
        <h3 class="font-bold text-lg mb-4 flex items-center gap-2">
          <.icon name="hero-sparkles" class="w-6 h-6" /> Browse Quality Profile Presets
        </h3>

        <%!-- Category filter tabs --%>
        <div class="tabs tabs-border mb-4">
          <button
            class={["tab", @selected_category == :all && "tab-active"]}
            phx-click="filter_presets"
            phx-value-category="all"
          >
            All
          </button>
          <button
            class={["tab", @selected_category == :trash_guides && "tab-active"]}
            phx-click="filter_presets"
            phx-value-category="trash_guides"
          >
            TRaSH Guides
          </button>
          <button
            class={["tab", @selected_category == :profilarr && "tab-active"]}
            phx-click="filter_presets"
            phx-value-category="profilarr"
          >
            Profilarr
          </button>
          <button
            class={["tab", @selected_category == :storage_optimized && "tab-active"]}
            phx-click="filter_presets"
            phx-value-category="storage_optimized"
          >
            Storage Optimized
          </button>
          <button
            class={["tab", @selected_category == :use_case && "tab-active"]}
            phx-click="filter_presets"
            phx-value-category="use_case"
          >
            Use Cases
          </button>
        </div>

        <%!-- Presets grid --%>
        <div class="overflow-y-auto flex-1">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <%= for preset <- @presets do %>
              <div class="card bg-base-200 shadow-sm hover:shadow-md transition-shadow">
                <div class="card-body p-4 space-y-2">
                  <%!-- Header with name and tags --%>
                  <div class="flex items-start justify-between gap-2">
                    <h4 class="font-semibold text-base">{preset.name}</h4>
                    <button
                      class="btn btn-sm btn-primary"
                      phx-click="import_preset"
                      phx-value-preset-id={preset.id}
                      title="Import this preset"
                    >
                      <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Import
                    </button>
                  </div>

                  <%!-- Description --%>
                  <p class="text-sm opacity-80 line-clamp-2">{preset.description}</p>

                  <%!-- Tags --%>
                  <div class="flex flex-wrap gap-1">
                    <%= for tag <- Enum.take(preset.tags, 5) do %>
                      <span class="badge badge-sm badge-ghost">{tag}</span>
                    <% end %>
                    <%= if length(preset.tags) > 5 do %>
                      <span class="badge badge-sm badge-ghost opacity-50">
                        +{length(preset.tags) - 5}
                      </span>
                    <% end %>
                  </div>

                  <%!-- Source info --%>
                  <div class="flex items-center justify-between text-xs opacity-60">
                    <span class="flex items-center gap-1">
                      <.icon name="hero-information-circle" class="w-3 h-3" />
                      {preset.source}
                    </span>
                    <%= if preset.source_url do %>
                      <a
                        href={preset.source_url}
                        target="_blank"
                        class="link link-hover flex items-center gap-1"
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" /> Docs
                      </a>
                    <% end %>
                  </div>

                  <%!-- Quick specs --%>
                  <% standards = preset.profile_data.quality_standards || %{} %>
                  <% resolutions = get_in(standards, [:preferred_resolutions]) || [] %>
                  <% video_codecs = get_in(standards, [:preferred_video_codecs]) || [] %>
                  <% sources = get_in(standards, [:preferred_sources]) || [] %>

                  <div class="text-xs space-y-1 pt-2 border-t border-base-300">
                    <%= if resolutions != [] do %>
                      <div class="flex gap-2">
                        <span class="font-medium min-w-[4rem]">Resolution:</span>
                        <span class="opacity-70">{Enum.join(resolutions, ", ")}</span>
                      </div>
                    <% end %>
                    <%= if video_codecs != [] do %>
                      <div class="flex gap-2">
                        <span class="font-medium min-w-[4rem]">Codecs:</span>
                        <span class="opacity-70">{Enum.join(video_codecs, ", ")}</span>
                      </div>
                    <% end %>
                    <%= if sources != [] do %>
                      <div class="flex gap-2">
                        <span class="font-medium min-w-[4rem]">Sources:</span>
                        <span class="opacity-70">{Enum.join(sources, ", ")}</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          </div>

          <%= if @presets == [] do %>
            <div class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span>No presets found for this category.</span>
            </div>
          <% end %>
        </div>

        <%!-- Footer --%>
        <div class="modal-action mt-4">
          <button type="button" class="btn" phx-click="close_browse_presets_modal">
            Close
          </button>
        </div>
      </div>
    </div>
    """
  end
end
