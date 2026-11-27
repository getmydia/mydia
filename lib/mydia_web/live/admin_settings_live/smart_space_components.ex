defmodule MydiaWeb.AdminSettingsLive.SmartSpaceComponents do
  @moduledoc """
  The Smart Space card of Admin Settings. Values and writes live in
  `MydiaWeb.AdminSettingsLive.SmartSpaceSettings`.
  """
  use MydiaWeb, :html

  alias Mydia.Config.Schema.SmartSpace

  attr :settings, :map, required: true
  attr :usernames, :list, required: true
  attr :error, :string, default: nil

  def smart_space_card(assigns) do
    assigns =
      assigns
      |> assign(:enabled, assigns.settings["smart_space.enabled"])
      |> assign(:unit, assigns.settings["smart_space.unit"])
      |> assign(:grace, assigns.settings["smart_space.grace_days"])
      |> assign(:watched_by, assigns.settings["smart_space.watched_by"])
      |> assign(:users, assigns.settings["smart_space.selected_users"])

    ~H"""
    <div id="smart-space-settings" class="card bg-base-200 mt-4">
      <.form for={%{}} id="smart-space-form" phx-submit="save_smart_space_settings">
        <div class="card-body gap-4">
          <div>
            <h3 class="card-title text-base">{gettext("Smart Space")}</h3>
            <p class="text-xs opacity-60">
              {gettext(
                "Moves watched TV to the trash for you, once everyone who matters has finished it. Nothing is deleted permanently."
              )}
            </p>
          </div>

          <div class="flex items-center gap-2 flex-wrap">
            <span class="font-medium">{gettext("Clean up watched TV")}</span>
            <.config_source_badge source={@enabled.source} />
            <input type="hidden" name="enabled" value="false" disabled={@enabled.source == :env} />
            <input
              id="smart-space-enabled"
              type="checkbox"
              name="enabled"
              value="true"
              class="toggle toggle-primary toggle-sm ml-auto"
              checked={@enabled.value}
              disabled={@enabled.source == :env}
            />
          </div>

          <label class="flex flex-col gap-1">
            <span class="font-medium flex items-center gap-2">
              {gettext("What to clean up")} <.config_source_badge source={@unit.source} />
            </span>
            <select
              id="smart-space-unit"
              name="unit"
              class="select select-sm select-bordered w-full sm:w-64"
              disabled={@unit.source == :env}
            >
              <option :for={value <- SmartSpace.units()} value={value} selected={value == @unit.value}>
                {unit_label(value)}
              </option>
            </select>
          </label>

          <label class="flex flex-col gap-1">
            <span class="font-medium flex items-center gap-2">
              {gettext("Grace period (days)")} <.config_source_badge source={@grace.source} />
            </span>
            <input
              id="smart-space-grace-days"
              type="number"
              min="0"
              step="1"
              name="grace_days"
              value={@grace.value}
              class="input input-sm input-bordered w-full sm:w-32"
              disabled={@grace.source == :env}
            />
            <span class="text-xs opacity-60">
              {gettext(
                "How long a finished season or episode stays put after it was last watched, so a rewatch can still happen."
              )}
            </span>
          </label>

          <label class="flex flex-col gap-1">
            <span class="font-medium flex items-center gap-2">
              {gettext("Who has to have watched it")}
              <.config_source_badge source={@watched_by.source} />
            </span>
            <select
              id="smart-space-watched-by"
              name="watched_by"
              class="select select-sm select-bordered w-full sm:w-64"
              disabled={@watched_by.source == :env}
            >
              <option
                :for={value <- SmartSpace.watched_by_values()}
                value={value}
                selected={value == @watched_by.value}
              >
                {watched_by_label(value)}
              </option>
            </select>
          </label>

          <div class="flex flex-col gap-1">
            <span class="font-medium flex items-center gap-2">
              {gettext("Selected people")} <.config_source_badge source={@users.source} />
            </span>
            <span class="text-xs opacity-60">
              {gettext("Used when the rule above is Selected people.")}
            </span>
            <div
              id="smart-space-selected-users"
              class="filter"
              role="group"
              aria-label={gettext("Selected people")}
            >
              <input type="hidden" name="selected_users[]" value="" disabled={@users.source == :env} />
              <input
                :for={name <- @usernames}
                id={"smart-space-user-#{name}"}
                type="checkbox"
                class="btn btn-sm"
                name="selected_users[]"
                value={name}
                aria-label={name}
                checked={name in @users.value}
                disabled={@users.source == :env}
              />
            </div>
          </div>

          <p :if={@error} id="smart-space-error" class="text-error text-sm">{@error}</p>

          <div class="card-actions justify-end">
            <button id="smart-space-save" type="submit" class="btn btn-primary btn-sm">
              {gettext("Save")}
            </button>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp unit_label("season"), do: gettext("Whole seasons")
  defp unit_label("episode"), do: gettext("Single episodes")

  defp watched_by_label("all_started"), do: gettext("Everyone who started the show")
  defp watched_by_label("any"), do: gettext("Any one person")
  defp watched_by_label("selected"), do: gettext("Selected people")
end
