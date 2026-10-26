defmodule MydiaWeb.AdminSettingsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias MydiaWeb.AdminSettingsLive.Labels
  alias MydiaWeb.AdminSettingsLive.LanguageComponents

  attr :config_settings_with_sources, :map, required: true
  attr :crash_report_stats, :map, required: true
  attr :invalid_config_settings, :list, default: []
  attr :hwaccel, Mydia.Streaming.HardwareAccel.Capabilities, required: true
  attr :language_settings, :map, required: true
  attr :player_enabled?, :boolean, required: true

  def general_settings_tab(assigns) do
    ~H"""
    <div
      :if={@invalid_config_settings != []}
      id="invalid-config-settings"
      class="alert alert-warning"
    >
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <div>
        <h3 class="font-bold">{gettext("Some saved settings are not being applied")}</h3>
        <p class="text-sm">
          {gettext(
            "These rows name a setting that no longer exists, or hold a value of the wrong type. They are skipped so the rest of your configuration still applies. Removing them is safe."
          )}
        </p>
        <ul class="mt-3 space-y-2">
          <li
            :for={%{setting: setting, reason: reason} <- @invalid_config_settings}
            id={"invalid-config-setting-#{String.replace(setting.key, ".", "-")}"}
            class="flex items-center justify-between gap-3"
          >
            <span class="font-mono text-sm">{reason}</span>
            <.row_action
              id={"delete-invalid-config-setting-#{String.replace(setting.key, ".", "-")}"}
              icon="hero-trash"
              title={gettext("Remove")}
              destructive
              phx-click="delete_invalid_config_setting"
              phx-value-id={setting.id}
            />
          </li>
        </ul>
      </div>
    </div>

    <LanguageComponents.language_section
      settings={@language_settings}
      player_enabled?={@player_enabled?}
    />

    <%!-- Settings Categories --%>
    <%= for {category, settings} <- @config_settings_with_sources do %>
      <.admin_section
        id={"settings-#{category_slug(category)}"}
        title={Labels.category(category)}
        icon={category_icon(category)}
      >
        <.admin_list
          id={"settings-#{category_slug(category)}-list"}
          items={rows_for(category, settings)}
        >
          <:row :let={row}>
            <%= case row do %>
              <% :hwaccel -> %>
                <.admin_row id="hwaccel-status">
                  <:title>{gettext("Hardware transcoding")}</:title>
                  <:details>
                    <div class="text-xs opacity-60">
                      <%= if @hwaccel.backend == :none do %>
                        {gettext("Unavailable: %{reason}", reason: @hwaccel.reason)}
                      <% else %>
                        {gettext("%{backend} on %{device}",
                          backend: @hwaccel.backend,
                          device: @hwaccel.device || gettext("unknown device")
                        )}
                        <%= if @hwaccel.decode_profiles != [] do %>
                          &middot; {gettext("decodes %{profiles}",
                            profiles: Enum.map_join(@hwaccel.decode_profiles, ", ", &to_string/1)
                          )}
                        <% end %>
                      <% end %>
                    </div>
                  </:details>
                  <:badges>
                    <span class={[
                      "badge",
                      if(@hwaccel.backend == :none, do: "badge-ghost", else: "badge-success")
                    ]}>
                      {if @hwaccel.backend == :none,
                        do: gettext("Software"),
                        else: gettext("Accelerated")}
                    </span>
                  </:badges>
                </.admin_row>
              <% setting -> %>
                <.admin_row id={"setting-#{String.replace(setting.key, ".", "-")}"}>
                  <:title>
                    {Labels.label(setting.key)} <.config_source_badge source={setting.source} />
                  </:title>
                  <:descriptor><span class="font-mono">{setting.key}</span></:descriptor>
                  <:details :if={Labels.description(setting.key)}>
                    {Labels.description(setting.key)}
                  </:details>
                  <:actions>
                    <.setting_value_control
                      setting={setting}
                      category={category}
                      editable={Map.get(setting, :editable, setting.source != :env)}
                    />
                  </:actions>
                </.admin_row>
            <% end %>
          </:row>
          <:empty>{gettext("No settings in this category.")}</:empty>
        </.admin_list>

        <.crash_report_stats
          :if={category == "Crash Reporting" and @crash_report_stats.enabled}
          stats={@crash_report_stats}
        />
      </.admin_section>
    <% end %>

    <%!-- Legend --%>
    <div class="text-xs opacity-60 flex flex-wrap gap-3 sm:gap-4 justify-center">
      <span class="flex items-center gap-1">
        <span class="badge badge-info badge-xs">ENV</span> {gettext("Environment (read-only)")}
      </span>
      <span class="flex items-center gap-1">
        <span class="badge badge-primary badge-xs">DB</span> {gettext("Database stored")}
      </span>
      <span class="flex items-center gap-1">
        <.config_source_badge source={:yaml} size="xs" /> {gettext("Config file")}
      </span>
      <span class="flex items-center gap-1">
        <span class="badge badge-ghost badge-xs">{gettext("Default")}</span> {gettext(
          "Built-in value"
        )}
      </span>
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
        <div class="stat-title">{gettext("Crash Reports")}</div>
        <div class="stat-value text-warning">{@stats.queued_reports}</div>
        <div class="stat-desc">{gettext("Queued")}</div>
      </div>
      <.link
        navigate={~p"/admin/errors"}
        id="tracked-errors-link"
        class="stat hover:bg-base-300 transition-colors cursor-pointer"
      >
        <div class="stat-figure text-primary">
          <.icon name="hero-magnifying-glass" class="w-8 h-8" />
        </div>
        <div class="stat-title">{gettext("Tracked")}</div>
        <div class="stat-value text-primary">
          {ngettext("%{count} error", "%{count} errors", @stats.tracked_errors)}
        </div>
        <div class="stat-desc link link-info">{gettext("View all →")}</div>
      </.link>
      <%= if @stats.queued_reports > 0 do %>
        <div class="stat">
          <div class="stat-figure">
            <button
              class="btn btn-warning btn-outline btn-sm"
              phx-click="clear_crash_queue"
              data-confirm={gettext("Clear all pending crash reports?")}
            >
              <.icon name="hero-trash" class="w-4 h-4" /> {pgettext("crash reports", "Clear")}
            </button>
          </div>
          <div class="stat-title">{gettext("Actions")}</div>
          <div class="stat-desc">{gettext("Clear pending reports")}</div>
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
      <% is_boolean(@setting.value) -> %>
        <%= if @editable do %>
          <label class="label cursor-pointer gap-2">
            <span class="label-text text-xs">
              {if @setting.value, do: gettext("On"), else: gettext("Off")}
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
            {if @setting.value, do: gettext("Enabled"), else: gettext("Disabled")}
          </span>
        <% end %>
      <% String.contains?(@setting.key, "secret") or String.contains?(@setting.key, "key") -> %>
        <span class="opacity-40 font-mono">
          <.icon name="hero-lock-closed" class="w-4 h-4 inline" /> ••••••••
        </span>
      <% (is_nil(@setting.value) or @setting.value == "") and not @editable -> %>
        <span class="badge badge-ghost badge-sm">{gettext("Not set")}</span>
      <% @editable -> %>
        <label class="input input-sm input-bordered flex items-center gap-2 w-full sm:w-44">
          <input
            type={if @setting.type == :integer, do: "number", else: "text"}
            class="grow font-mono text-sm"
            value={@setting.value || ""}
            placeholder={Labels.placeholder(@setting.key) || Map.get(@setting, :placeholder, "")}
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

  defp category_slug(category),
    do: category |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  defp rows_for("Streaming", settings), do: settings ++ [:hwaccel]
  defp rows_for(_category, settings), do: settings

  defp category_icon("Server"), do: "hero-server"
  defp category_icon("Database"), do: "hero-circle-stack"
  defp category_icon("Authentication"), do: "hero-finger-print"
  defp category_icon("Media"), do: "hero-film"
  defp category_icon("Downloads"), do: "hero-arrow-down-tray"
  defp category_icon("Streaming"), do: "hero-play-circle"
  defp category_icon("Crash Reporting"), do: "hero-bug-ant"
  defp category_icon("Notifications"), do: "hero-bell"
  defp category_icon("Library"), do: "hero-folder-open"
  defp category_icon("Updates"), do: "hero-arrow-path"
  defp category_icon(_), do: "hero-cog-6-tooth"
end
