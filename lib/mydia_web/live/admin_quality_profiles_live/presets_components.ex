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
