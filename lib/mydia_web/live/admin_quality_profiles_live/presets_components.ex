defmodule MydiaWeb.AdminQualityProfilesLive.PresetsComponents do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  Renders the Browse Presets modal for quality profiles.
  """
  attr :presets, :list, required: true
  attr :selected_category, :atom, default: :all

  def browse_presets_modal(assigns) do
    ~H"""
    <.admin_modal
      id="quality-profile-presets-modal"
      size={:lg}
      icon="hero-sparkles"
      title="Browse Quality Profile Presets"
      subtitle="Start from a community-tested profile"
      on_close="close_quality_profile_presets_modal"
    >
      <div class="overflow-x-auto mb-4">
        <.segmented_control
          id="quality-profile-presets-filter"
          value={@selected_category}
          event="filter_quality_profile_presets"
          param="category"
          label="Filter presets by source"
        >
          <:option value="all" label="All" />
          <:option value="trash_guides" label="TRaSH Guides" />
          <:option value="profilarr" label="Profilarr" />
          <:option value="storage_optimized" label="Storage Optimized" />
          <:option value="use_case" label="Use Cases" />
        </.segmented_control>
      </div>

      <.admin_list id="quality-profile-presets" items={@presets}>
        <:empty>No presets found for this category.</:empty>
        <:row :let={preset}>
          <% standards = preset.profile_data.quality_standards || %{} %>
          <% resolutions = get_in(standards, [:preferred_resolutions]) || [] %>
          <% video_codecs = get_in(standards, [:preferred_video_codecs]) || [] %>
          <% sources = get_in(standards, [:preferred_sources]) || [] %>
          <.admin_row id={"preset-#{preset.id}"}>
            <:title>{preset.name}</:title>
            <:descriptor>{preset.description}</:descriptor>
            <:details>
              <div class="flex flex-wrap gap-1">
                <%= for tag <- Enum.take(preset.tags, 5) do %>
                  <span class="badge badge-sm badge-ghost">{tag}</span>
                <% end %>
                <span :if={length(preset.tags) > 5} class="badge badge-sm badge-ghost opacity-50">
                  +{length(preset.tags) - 5}
                </span>
              </div>
              <div class="flex items-center gap-3 text-xs opacity-60">
                <span class="flex items-center gap-1">
                  <.icon name="hero-information-circle" class="w-3 h-3" />
                  {preset.source}
                </span>
                <a
                  :if={preset.source_url}
                  href={preset.source_url}
                  target="_blank"
                  class="link link-hover flex items-center gap-1"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" /> Docs
                </a>
              </div>
              <div :if={resolutions != []} class="text-xs flex gap-2">
                <span class="font-medium min-w-[4rem]">Resolution:</span>
                <span class="opacity-70">{Enum.join(resolutions, ", ")}</span>
              </div>
              <div :if={video_codecs != []} class="text-xs flex gap-2">
                <span class="font-medium min-w-[4rem]">Codecs:</span>
                <span class="opacity-70">{Enum.join(video_codecs, ", ")}</span>
              </div>
              <div :if={sources != []} class="text-xs flex gap-2">
                <span class="font-medium min-w-[4rem]">Sources:</span>
                <span class="opacity-70">{Enum.join(sources, ", ")}</span>
              </div>
            </:details>
            <:actions>
              <.row_actions>
                <.row_action
                  id={"import-preset-#{preset.id}"}
                  icon="hero-arrow-down-tray"
                  title="Import preset"
                  phx-click="import_quality_profile_preset"
                  phx-value-preset-id={preset.id}
                />
              </.row_actions>
            </:actions>
          </.admin_row>
        </:row>
      </.admin_list>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="close_quality_profile_presets_modal">
          Close
        </button>
      </:actions>
    </.admin_modal>
    """
  end
end
