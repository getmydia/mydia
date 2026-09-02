defmodule MydiaWeb.AddMediaComponents do
  @moduledoc """
  The Configure Before Adding dialog.

  This is the only add dialog. It replaced a two-step flow where a caret opened
  `LibraryComponents.library_picker_dialog/1` ("Add to which library?") and that
  dialog carried a Configure entry to reach this one. The picker is gone; the
  caret opens this directly on every host.

  Everything item-specific arrives in one `config` map so a host's page-level
  media type cannot diverge from the clicked item's own, which it could when
  Discover passed `media_type` and `libraries` separately.

  Hosted by DiscoverLive, DashboardLive and MediaLive.Show. It is imported
  directly by each rather than added to `html_helpers`, and lives here rather
  than in `discover_components.ex`, which would cross the ~500 LOC guideline.
  """
  use MydiaWeb, :html

  @doc """
  Renders the dialog for the card in `config`, or nothing when `config` is nil.

  `config` is `%{ref:, media_type:, defaults:, preview:, libraries:}`,
  built by `MydiaWeb.Live.Helpers.MediaAddHelpers.put_add_config/4`. `preview`
  is `%{title:, year:, poster_path:, overview:}` and any of its values except
  the title may be nil.

  `z-[1000]` puts this above `TrendingDetailModal`, itself a `.modal` at
  z-index 999, without depending on template ordering: the caret that opens
  this is also reachable from the recommendations rail inside that modal.

  `phx-window-keydown` with `phx-key="Escape"` exists because a `<dialog>`
  toggled through the `open` attribute, unlike one opened with `showModal()`,
  gets neither native Escape handling nor a `::backdrop`. The explicit
  `modal-backdrop` click target is the other half of that workaround. Hosts
  that also render `TrendingDetailModal` must pass it `config_open` so a single
  Escape press does not close both layers.
  """
  attr :config, :map, default: nil
  attr :quality_profiles, :list, default: []

  def add_config_modal(assigns) do
    ~H"""
    <dialog
      id="add-config-modal"
      class="modal z-[1000]"
      open={@config != nil}
      phx-window-keydown={@config && "close_add_config"}
      phx-key="Escape"
    >
      <div :if={@config} class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">Configure Before Adding</h3>
        <%!-- Media Preview --%>
        <div class="flex gap-4 mb-6 bg-base-300 p-4 rounded-lg">
          <div class="w-20 flex-shrink-0">
            <img
              src={get_poster_url(@config.preview)}
              alt={@config.preview.title}
              class="w-full rounded"
            />
          </div>
          <div class="flex-1 min-w-0">
            <h4 class="font-bold text-base">{@config.preview.title}</h4>
            <p class="text-sm text-base-content/70">{format_year(@config.preview)}</p>
            <%= if @config.preview.overview do %>
              <p class="text-xs text-base-content/60 mt-2 line-clamp-3">
                {@config.preview.overview}
              </p>
            <% end %>
          </div>
        </div>
        <%!-- Configuration Form --%>
        <.form for={%{}} phx-submit="submit_add_config" id="add-config-form">
          <%!-- Library Path --%>
          <div class="form-control mb-4">
            <label class="label">
              <span class="label-text font-semibold">Root Folder</span>
              <span class="label-text-alt text-error">*</span>
            </label>
            <%= if @config.libraries == [] do %>
              <div class="alert alert-warning">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                <span>No library paths configured. Please configure a library path first.</span>
              </div>
            <% else %>
              <select name="config[library_path_id]" class="select select-bordered" required>
                <option value="">Select a folder...</option>
                <%= for path <- @config.libraries do %>
                  <option
                    value={path.id}
                    selected={@config.defaults.library_path_id == path.id}
                  >
                    {Path.basename(path.path)} · {path.path}
                  </option>
                <% end %>
              </select>
            <% end %>
          </div>
          <%!-- Quality Profile --%>
          <div class="form-control mb-4">
            <label class="label">
              <span class="label-text font-semibold">Quality Profile</span>
            </label>
            <select name="config[quality_profile_id]" class="select select-bordered">
              <option value="">Use server default</option>
              <%= for profile <- @quality_profiles do %>
                <option
                  value={profile.id}
                  selected={@config.defaults.quality_profile_id == profile.id}
                >
                  {profile.name}
                </option>
              <% end %>
            </select>
          </div>
          <%!-- Monitoring --%>
          <div class="form-control mb-4">
            <label class="label cursor-pointer justify-start gap-4">
              <input type="hidden" name="config[monitored]" value="false" />
              <input
                type="checkbox"
                name="config[monitored]"
                value="true"
                class="toggle toggle-primary"
                checked={@config.defaults.monitored}
              />
              <div>
                <span class="label-text font-semibold">
                  Monitor this {(@config.media_type == :movie && "movie") || "series"}
                </span>
                <p class="text-xs text-base-content/60">
                  Automatically search for and download new releases
                </p>
              </div>
            </label>
          </div>
          <%!-- Season Monitoring for TV --%>
          <%= if @config.media_type == :tv_show do %>
            <div class="form-control mb-4">
              <label class="label">
                <span class="label-text font-semibold">Season Monitoring</span>
              </label>
              <select name="config[season_monitoring]" class="select select-bordered">
                <option value="all" selected={@config.defaults.season_monitoring == "all"}>
                  Monitor All Seasons
                </option>
                <option value="first" selected={@config.defaults.season_monitoring == "first"}>
                  Monitor First Season Only
                </option>
                <option value="future" selected={@config.defaults.season_monitoring == "future"}>
                  Monitor Future Seasons
                </option>
                <option value="none" selected={@config.defaults.season_monitoring == "none"}>
                  Don't Monitor Any Seasons
                </option>
              </select>
            </div>
          <% end %>
          <%!-- Search on Add --%>
          <div class="form-control mb-6">
            <label class="label cursor-pointer justify-start gap-4">
              <input type="hidden" name="config[search_on_add]" value="false" />
              <input
                type="checkbox"
                name="config[search_on_add]"
                value="true"
                class="toggle toggle-primary"
                checked={@config.defaults.search_on_add}
              />
              <div>
                <span class="label-text font-semibold">Search on Add</span>
                <p class="text-xs text-base-content/60">
                  Trigger an immediate search for this media after adding
                </p>
              </div>
            </label>
          </div>
          <%!-- Modal Actions --%>
          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_add_config">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary" disabled={@config.libraries == []}>
              <.icon name="hero-plus" class="w-5 h-5" /> Add to Library
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_add_config"></div>
    </dialog>
    """
  end

  defp get_poster_url(%{poster_path: nil}), do: "/images/no-poster.svg"
  defp get_poster_url(%{poster_path: path}), do: ImageUrl.poster_url(path)
  defp get_poster_url(_preview), do: "/images/no-poster.svg"

  defp format_year(%{year: year}) when is_integer(year), do: to_string(year)
  defp format_year(_preview), do: "N/A"
end
