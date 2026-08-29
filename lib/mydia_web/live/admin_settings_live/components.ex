defmodule MydiaWeb.AdminSettingsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  attr :config_settings_with_sources, :map, required: true
  attr :crash_report_stats, :map, required: true
  attr :invalid_config_settings, :list, default: []

  def general_settings_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-6 sm:space-y-8">
      <div
        :if={@invalid_config_settings != []}
        id="invalid-config-settings"
        class="alert alert-warning mb-6"
      >
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div>
          <h3 class="font-bold">Some saved settings are not being applied</h3>
          <p class="text-sm">
            These rows name a setting that no longer exists, or hold a value of the
            wrong type. They are skipped so the rest of your configuration still
            applies. Removing them is safe.
          </p>
          <ul class="mt-3 space-y-2">
            <li
              :for={%{setting: setting, reason: reason} <- @invalid_config_settings}
              id={"invalid-config-setting-#{String.replace(setting.key, ".", "-")}"}
              class="flex items-center justify-between gap-3"
            >
              <span class="font-mono text-sm">{reason}</span>
              <button
                type="button"
                id={"delete-invalid-config-setting-#{String.replace(setting.key, ".", "-")}"}
                class="btn btn-sm btn-ghost"
                phx-click="delete_invalid_config_setting"
                phx-value-id={setting.id}
              >
                Remove
              </button>
            </li>
          </ul>
        </div>
      </div>
      <%!-- Settings Categories --%>
      <%= for {category, settings} <- @config_settings_with_sources do %>
        <div class="space-y-2">
          <h3 class="font-semibold flex items-center gap-2 px-1">
            <.icon name={category_icon(category)} class="w-4 h-4 opacity-60" />
            {category}
          </h3>

          <div class="bg-base-200 rounded-box divide-y divide-base-300">
            <%= for setting <- settings do %>
              <div class="p-3 sm:p-4">
                <div class="flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-4">
                  <div class="flex-1 min-w-0">
                    <div class="font-medium flex items-center gap-2 flex-wrap">
                      {setting.label}
                      <.setting_source_badge source={setting.source} />
                    </div>
                    <div class="text-xs opacity-50 font-mono truncate">{setting.key}</div>
                    <%= if Map.get(setting, :description) do %>
                      <div class="text-xs opacity-60 mt-1">{setting.description}</div>
                    <% end %>
                  </div>
                  <div class="sm:ml-auto">
                    <.setting_value_control
                      setting={setting}
                      category={category}
                      editable={Map.get(setting, :editable, setting.source != :env)}
                    />
                  </div>
                </div>
              </div>
            <% end %>
          </div>

          <%= if category == "Crash Reporting" and @crash_report_stats.enabled do %>
            <.crash_report_stats stats={@crash_report_stats} />
          <% end %>
        </div>
      <% end %>

      <%!-- Legend --%>
      <div class="text-xs opacity-60 flex flex-wrap gap-3 sm:gap-4 justify-center">
        <span class="flex items-center gap-1">
          <span class="badge badge-info badge-xs">ENV</span> Environment (read-only)
        </span>
        <span class="flex items-center gap-1">
          <span class="badge badge-primary badge-xs">DB</span> Database stored
        </span>
        <span class="flex items-center gap-1">
          <span class="badge badge-ghost badge-xs">Default</span> Built-in value
        </span>
      </div>
    </div>
    """
  end

  attr :stats, :map, required: true

  defp crash_report_stats(assigns) do
    ~H"""
    <div class="stats stats-vertical sm:stats-horizontal shadow bg-base-200 w-full mt-2">
      <div class="stat">
        <div class="stat-figure text-warning">
          <.icon name="hero-bug-ant" class="w-8 h-8" />
        </div>
        <div class="stat-title">Crash Reports</div>
        <div class="stat-value text-warning">{@stats.queued_reports}</div>
        <div class="stat-desc">Queued</div>
      </div>
      <.link
        navigate={~p"/admin/errors"}
        id="tracked-errors-link"
        class="stat hover:bg-base-300 transition-colors cursor-pointer"
      >
        <div class="stat-figure text-info">
          <.icon name="hero-magnifying-glass" class="w-8 h-8" />
        </div>
        <div class="stat-title">Tracked</div>
        <div class="stat-value text-info">
          {@stats.tracked_errors}
          <span class="text-base font-normal">
            {if @stats.tracked_errors == 1, do: "error", else: "errors"}
          </span>
        </div>
        <div class="stat-desc link link-info">View all →</div>
      </.link>
      <%= if @stats.queued_reports > 0 do %>
        <div class="stat">
          <div class="stat-figure">
            <button
              class="btn btn-warning btn-outline btn-sm"
              phx-click="clear_crash_queue"
              data-confirm="Clear all pending crash reports?"
            >
              <.icon name="hero-trash" class="w-4 h-4" /> Clear
            </button>
          </div>
          <div class="stat-title">Actions</div>
          <div class="stat-desc">Clear pending reports</div>
        </div>
      <% end %>
    </div>
    """
  end

  # Setting value control component
  attr :setting, :map, required: true
  attr :category, :string, required: true
  attr :editable, :boolean, default: true

  defp setting_value_control(assigns) do
    ~H"""
    <%= cond do %>
      <% @setting.type == :select -> %>
        <%= if @editable do %>
          <select
            class="select select-sm select-bordered w-full sm:w-56"
            phx-change="update_select_setting"
            phx-value-key={@setting.key}
            phx-value-category={@category}
            name="value"
          >
            <%= for {value, label} <- @setting.options do %>
              <option value={value || ""} selected={@setting.value == value}>
                {label}
              </option>
            <% end %>
          </select>
        <% else %>
          <% label = Enum.find_value(@setting.options, fn {v, l} -> v == @setting.value && l end) %>
          <kbd class="kbd kbd-sm font-mono">{label || "Not set"}</kbd>
        <% end %>
      <% is_boolean(@setting.value) -> %>
        <%= if @editable do %>
          <label class="label cursor-pointer gap-2">
            <span class="label-text text-xs">
              {if @setting.value, do: "On", else: "Off"}
            </span>
            <input
              type="checkbox"
              class="toggle toggle-primary toggle-sm"
              value="true"
              checked={@setting.value}
              phx-click="toggle_setting"
              phx-value-key={@setting.key}
              phx-value-category={@category}
              phx-value-next_value={to_string(!@setting.value)}
            />
          </label>
        <% else %>
          <span class={[
            "badge",
            if(@setting.value, do: "badge-success", else: "badge-ghost")
          ]}>
            {if @setting.value, do: "Enabled", else: "Disabled"}
          </span>
        <% end %>
      <% String.contains?(@setting.key, "secret") or String.contains?(@setting.key, "key") -> %>
        <span class="opacity-40 font-mono">
          <.icon name="hero-lock-closed" class="w-4 h-4 inline" /> ••••••••
        </span>
      <% (is_nil(@setting.value) or @setting.value == "") and not @editable -> %>
        <span class="badge badge-ghost badge-sm">Not set</span>
      <% @editable -> %>
        <label class="input input-sm input-bordered flex items-center gap-2 w-full sm:w-44">
          <input
            type={if @setting.type == :integer, do: "number", else: "text"}
            class="grow font-mono text-sm"
            value={@setting.value || ""}
            placeholder={Map.get(@setting, :placeholder, "")}
            phx-debounce="1000"
            phx-blur="update_setting_form"
            phx-value-key={@setting.key}
            phx-value-category={@category}
          />
          <%= if @setting.type == :integer do %>
            <.icon name="hero-hashtag" class="w-3 h-3 opacity-40" />
          <% end %>
        </label>
      <% true -> %>
        <kbd class="kbd kbd-sm font-mono">{@setting.value}</kbd>
    <% end %>
    """
  end

  attr :source, :atom, required: true

  defp setting_source_badge(assigns) do
    ~H"""
    <%= case @source do %>
      <% :env -> %>
        <span class="badge badge-info badge-sm">ENV</span>
      <% :database -> %>
        <span class="badge badge-primary badge-sm">DB</span>
      <% :yaml -> %>
        <span class="badge badge-secondary badge-sm">YAML</span>
      <% _ -> %>
        <span class="badge badge-ghost badge-sm">Default</span>
    <% end %>
    """
  end

  defp category_icon("Server"), do: "hero-server"
  defp category_icon("Database"), do: "hero-circle-stack"
  defp category_icon("Authentication"), do: "hero-finger-print"
  defp category_icon("Media"), do: "hero-film"
  defp category_icon("Metadata"), do: "hero-language"
  defp category_icon("Downloads"), do: "hero-arrow-down-tray"
  defp category_icon("Streaming"), do: "hero-play-circle"
  defp category_icon("Crash Reporting"), do: "hero-bug-ant"
  defp category_icon("Notifications"), do: "hero-bell"
  defp category_icon("Library"), do: "hero-folder-open"
  defp category_icon(_), do: "hero-cog-6-tooth"
end
