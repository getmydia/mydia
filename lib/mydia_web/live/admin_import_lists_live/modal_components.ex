defmodule MydiaWeb.AdminImportListsLive.ModalComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.ImportLists.ImportList
  alias MydiaWeb.AdminImportListsLive.Index

  @source_options [
    {"-- TMDB Preset Lists --", ""},
    {"Trending", "tmdb_trending"},
    {"Popular", "tmdb_popular"},
    {"Upcoming (Movies)", "tmdb_upcoming"},
    {"Now Playing (Movies)", "tmdb_now_playing"},
    {"On The Air (TV)", "tmdb_on_the_air"},
    {"Airing Today (TV)", "tmdb_airing_today"},
    {"-- Custom Lists --", ""},
    {"TMDB User List", "tmdb_list"},
    {"Custom URL (JSON)", "custom_url"}
  ]

  @sync_interval_options [
    {"Every hour", 60},
    {"Every 6 hours", 360},
    {"Every 12 hours", 720},
    {"Every 24 hours", 1440}
  ]

  attr :import_list_form, :any, required: true
  attr :import_list_mode, :atom, required: true
  attr :selected_list, :any, required: true
  attr :quality_profiles, :list, required: true
  attr :library_paths, :list, required: true
  attr :manual_collections, :list, required: true

  def import_list_modal(assigns) do
    assigns =
      assigns
      |> assign(:source_options, @source_options)
      |> assign(:sync_interval_options, @sync_interval_options)
      |> assign(:selected_type, Phoenix.HTML.Form.input_value(assigns.import_list_form, :type))

    ~H"""
    <.admin_modal
      id="import-list-modal"
      icon="hero-queue-list"
      title={if @import_list_mode == :new, do: "Create Import List", else: "Edit Import List"}
      on_close="close_import_list_modal"
    >
      <.form
        for={@import_list_form}
        id="import-list-form"
        phx-change="validate_import_list"
        phx-submit="save_import_list"
      >
        <div class="space-y-4">
          <.input field={@import_list_form[:name]} type="text" label="Name" required />

          <%= if @import_list_mode == :new do %>
            <.input
              field={@import_list_form[:type]}
              type="select"
              label="List Source"
              options={@source_options}
              required
            />

            <.input
              :if={ImportList.requires_config?(@selected_type)}
              field={@import_list_form[:list_url]}
              type="text"
              label={ImportList.config_field_label(@selected_type)}
              placeholder={ImportList.config_field_placeholder(@selected_type)}
              required
            />

            <.input
              field={@import_list_form[:media_type]}
              type="select"
              label="Media Type"
              options={Index.media_type_options(@selected_type)}
              required
            />
          <% else %>
            <div class="form-control">
              <label class="label"><span class="label-text">List Type</span></label>
              <input
                type="text"
                value={ImportList.type_label(@selected_list.type)}
                class="input input-bordered"
                disabled
              />
            </div>

            <.input
              :if={ImportList.requires_config?(@selected_list.type)}
              field={@import_list_form[:list_url]}
              type="text"
              label={ImportList.config_field_label(@selected_list.type)}
              placeholder={ImportList.config_field_placeholder(@selected_list.type)}
              value={@selected_list.config["list_url"]}
            />

            <div class="form-control">
              <label class="label"><span class="label-text">Media Type</span></label>
              <input
                type="text"
                value={if @selected_list.media_type == "movie", do: "Movies", else: "TV Shows"}
                class="input input-bordered"
                disabled
              />
            </div>
          <% end %>

          <.input
            field={@import_list_form[:sync_interval]}
            type="select"
            label="Sync Interval"
            options={@sync_interval_options}
          />

          <.input
            field={@import_list_form[:quality_profile_id]}
            type="select"
            label="Quality Profile (Optional)"
            options={[{"Default", nil}] ++ Enum.map(@quality_profiles, &{&1.name, &1.id})}
            prompt="Select quality profile..."
          />

          <.input
            field={@import_list_form[:library_path_id]}
            type="select"
            label="Library Path (Optional)"
            options={[{"Default", nil}] ++ Enum.map(@library_paths, &{&1.path, &1.id})}
            prompt="Select library path..."
          />

          <.input
            field={@import_list_form[:target_collection_id]}
            type="select"
            label="Target Collection (Optional)"
            options={[{"None", nil}] ++ Enum.map(@manual_collections, &{&1.name, &1.id})}
            prompt="Auto-add to collection..."
          />
          <p class="text-xs text-base-content/50 -mt-2 ml-1">
            Items will be automatically added to this collection when imported
          </p>

          <div class="divider text-sm text-base-content/60">Behavior</div>

          <div class="flex flex-col gap-3">
            <.behavior_checkbox
              field={@import_list_form[:auto_add]}
              label="Auto-add to library"
              hint="Automatically add new items without manual approval"
              warning="Added items appear in your library immediately. When the list is also monitored, they are searched for on indexers and downloaded automatically."
            />
            <.behavior_checkbox
              field={@import_list_form[:monitored]}
              label="Monitor new items"
              hint="Automatically search for downloads when items are added"
            />
            <.behavior_checkbox
              field={@import_list_form[:enabled]}
              label="Enabled"
              hint="Enable automatic syncing"
              color="checkbox-success"
            />
          </div>
        </div>

        <.admin_modal_actions>
          <button type="button" phx-click="close_import_list_modal" class="btn btn-ghost">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary">
            {if @import_list_mode == :new, do: "Create", else: "Save"}
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :hint, :string, required: true
  attr :warning, :string, default: nil
  attr :color, :string, default: "checkbox-primary"

  defp behavior_checkbox(assigns) do
    ~H"""
    <label class="flex items-center gap-3 cursor-pointer">
      <input type="hidden" name={@field.name} value="false" />
      <input
        type="checkbox"
        name={@field.name}
        value="true"
        checked={Phoenix.HTML.Form.normalize_value("checkbox", @field.value)}
        class={["checkbox checkbox-sm", @color]}
      />
      <div>
        <span class="font-medium">{@label}</span>
        <p class="text-xs text-base-content/60">{@hint}</p>
        <p :if={@warning} class="text-xs text-warning">{@warning}</p>
      </div>
    </label>
    """
  end

  attr :pending_preset_id, :string, required: true

  def preset_confirm_modal(assigns) do
    ~H"""
    <.admin_modal
      id="preset-confirm-modal"
      icon="hero-question-mark-circle"
      title={"Enable #{Index.get_preset_name(@pending_preset_id)}?"}
      subtitle="How would you like to handle new items from this list?"
      on_close="close_preset_confirm_modal"
    >
      <div class="space-y-3">
        <button
          id="confirm-preset-auto-add"
          type="button"
          phx-click="confirm_enable_preset"
          phx-value-auto-add="true"
          class="w-full text-left bg-base-200 hover:bg-base-300 rounded-box p-4 transition-colors"
        >
          <div class="flex items-start gap-3">
            <.icon name="hero-bolt" class="w-6 h-6 text-warning shrink-0 mt-0.5" />
            <div>
              <h4 class="font-semibold">Yes, auto-add new items</h4>
              <p class="text-sm text-base-content/60 mt-1">
                New items will be automatically added to your library when synced.
                Good if you trust this list's selections.
              </p>
            </div>
          </div>
        </button>

        <button
          id="confirm-preset-review"
          type="button"
          phx-click="confirm_enable_preset"
          phx-value-auto-add="false"
          class="w-full text-left bg-base-200 hover:bg-base-300 rounded-box p-4 transition-colors"
        >
          <div class="flex items-start gap-3">
            <.icon name="hero-eye" class="w-6 h-6 text-primary shrink-0 mt-0.5" />
            <div>
              <h4 class="font-semibold">No, I'll review first</h4>
              <p class="text-sm text-base-content/60 mt-1">
                Items will be marked as "pending" and you can add them manually.
                Best for discovering new content at your own pace.
              </p>
            </div>
          </div>
        </button>
      </div>

      <:actions>
        <button type="button" phx-click="close_preset_confirm_modal" class="btn btn-ghost">
          Cancel
        </button>
      </:actions>
    </.admin_modal>
    """
  end
end
