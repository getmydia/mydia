defmodule MydiaWeb.AdminImportListsLive.ModalComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.ImportLists.ImportList
  alias MydiaWeb.AdminImportListsLive.Index

  defp source_options do
    [
      {gettext("-- TMDB Preset Lists --"), ""},
      {gettext("Trending"), "tmdb_trending"},
      {gettext("Popular"), "tmdb_popular"},
      {gettext("Upcoming (Movies)"), "tmdb_upcoming"},
      {gettext("Now Playing (Movies)"), "tmdb_now_playing"},
      {gettext("On The Air (TV)"), "tmdb_on_the_air"},
      {gettext("Airing Today (TV)"), "tmdb_airing_today"},
      {gettext("-- Custom Lists --"), ""},
      {gettext("TMDB User List"), "tmdb_list"},
      {gettext("Custom URL (JSON)"), "custom_url"}
    ]
  end

  defp sync_interval_options do
    [
      {gettext("Every hour"), 60},
      {gettext("Every 6 hours"), 360},
      {gettext("Every 12 hours"), 720},
      {gettext("Every 24 hours"), 1440}
    ]
  end

  attr :import_list_form, :any, required: true
  attr :import_list_mode, :atom, required: true
  attr :selected_list, :any, required: true
  attr :quality_profiles, :list, required: true
  attr :library_paths, :list, required: true
  attr :manual_collections, :list, required: true

  def import_list_modal(assigns) do
    assigns =
      assigns
      |> assign(:source_options, source_options())
      |> assign(:sync_interval_options, sync_interval_options())
      |> assign(:selected_type, Phoenix.HTML.Form.input_value(assigns.import_list_form, :type))
      |> assign(
        :selected_media_type,
        Phoenix.HTML.Form.input_value(assigns.import_list_form, :media_type)
      )
      |> assign(
        :selected_library_path_id,
        Phoenix.HTML.Form.input_value(assigns.import_list_form, :library_path_id)
      )

    ~H"""
    <.admin_modal
      id="import-list-modal"
      icon="hero-queue-list"
      title={
        if @import_list_mode == :new,
          do: gettext("Create Import List"),
          else: gettext("Edit Import List")
      }
      on_close="close_import_list_modal"
    >
      <.form
        for={@import_list_form}
        id="import-list-form"
        phx-change="validate_import_list"
        phx-submit="save_import_list"
      >
        <div class="space-y-4">
          <.input field={@import_list_form[:name]} type="text" label={gettext("Name")} required />

          <%= if @import_list_mode == :new do %>
            <.input
              field={@import_list_form[:type]}
              type="select"
              label={gettext("List Source")}
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
              label={gettext("Media Type")}
              options={Index.media_type_options(@selected_type)}
              required
            />
          <% else %>
            <div class="form-control">
              <label class="label"><span class="label-text">{gettext("List Type")}</span></label>
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
              <label class="label"><span class="label-text">{gettext("Media Type")}</span></label>
              <input
                type="text"
                value={
                  if @selected_list.media_type == "movie",
                    do: gettext("Movies"),
                    else: gettext("TV Shows")
                }
                class="input input-bordered"
                disabled
              />
            </div>
          <% end %>

          <.input
            field={@import_list_form[:sync_interval]}
            type="select"
            label={gettext("Sync Interval")}
            options={@sync_interval_options}
          />

          <.input
            field={@import_list_form[:quality_profile_id]}
            type="select"
            label={gettext("Quality Profile (Optional)")}
            options={[{gettext("Default"), nil}] ++ Enum.map(@quality_profiles, &{&1.name, &1.id})}
            prompt={gettext("Select quality profile...")}
          />

          <.input
            field={@import_list_form[:library_path_id]}
            type="select"
            label={gettext("Library Path (Optional)")}
            options={
              Index.library_path_options(
                @library_paths,
                @selected_media_type,
                @selected_library_path_id
              )
            }
            prompt={gettext("Select library path...")}
          />

          <.input
            field={@import_list_form[:target_collection_id]}
            type="select"
            label={gettext("Target Collection (Optional)")}
            options={
              [{pgettext("selection", "None"), nil}] ++
                Enum.map(@manual_collections, &{&1.name, &1.id})
            }
            prompt={gettext("Auto-add to collection...")}
          />
          <p class="text-xs text-base-content/50 -mt-2 ml-1">
            {gettext("Items will be automatically added to this collection when imported")}
          </p>

          <div class="divider text-sm text-base-content/60">{gettext("Behavior")}</div>

          <div class="flex flex-col gap-3">
            <.behavior_checkbox
              field={@import_list_form[:auto_add]}
              label={gettext("Auto-add to library")}
              hint={gettext("Automatically add new items without manual approval")}
              warning={
                gettext(
                  "Added items appear in your library immediately. When the list is also monitored, they are searched for on indexers and downloaded automatically."
                )
              }
            />
            <.behavior_checkbox
              field={@import_list_form[:monitored]}
              label={gettext("Monitor new items")}
              hint={gettext("Automatically search for downloads when items are added")}
            />
            <.behavior_checkbox
              field={@import_list_form[:enabled]}
              label={gettext("Enabled")}
              hint={gettext("Enable automatic syncing")}
              color="checkbox-success"
            />
          </div>
        </div>

        <.admin_modal_actions>
          <button type="button" phx-click="close_import_list_modal" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary">
            {if @import_list_mode == :new, do: gettext("Create"), else: gettext("Save")}
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
      title={gettext("Enable %{name}?", name: Index.get_preset_name(@pending_preset_id))}
      subtitle={gettext("How would you like to handle new items from this list?")}
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
              <h4 class="font-semibold">{gettext("Yes, auto-add new items")}</h4>
              <p class="text-sm text-base-content/60 mt-1">
                {gettext("New items will be automatically added to your library when synced.")}
                {gettext("Good if you trust this list's selections.")}
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
              <h4 class="font-semibold">{gettext("No, I'll review first")}</h4>
              <p class="text-sm text-base-content/60 mt-1">
                {gettext("Items will be marked as \"pending\" and you can add them manually.")}
                {gettext("Best for discovering new content at your own pace.")}
              </p>
            </div>
          </div>
        </button>
      </div>

      <:actions>
        <button type="button" phx-click="close_preset_confirm_modal" class="btn btn-ghost">
          {gettext("Cancel")}
        </button>
      </:actions>
    </.admin_modal>
    """
  end
end
