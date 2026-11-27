defmodule MydiaWeb.MediaLive.Show.SmartSpaceComponents do
  @moduledoc """
  Smart Space controls on the TV show page: the menu entry, the override
  modal, the "cleans up" badge and the Keep toggles.

  Every function takes the `smart_space` map built in `show.html.heex`
  (`rule`, `override`, `due`, `keeps`, `can_edit?`, `can_keep?`), or `nil` on a
  movie page, where nothing renders.
  """

  use MydiaWeb, :html

  @doc "The `Smart Space: Inherit (season, 7 days)` line of the monitoring menu."
  attr :smart_space, :map, default: nil

  def menu_entry(%{smart_space: nil} = assigns), do: ~H""

  def menu_entry(assigns) do
    ~H"""
    <li class="border-t border-base-300 mt-1 pt-1">
      <button
        type="button"
        id="smart-space-menu"
        popovertarget="episode-monitoring-menu-panel"
        popovertargetaction="hide"
        phx-click="smart_space_open"
        disabled={!@smart_space.can_edit?}
      >
        <.icon name="hero-sparkles" class="w-4 h-4" />
        <span>{menu_label(@smart_space)}</span>
      </button>
    </li>
    """
  end

  @doc "The override modal, rendered at page level like the quality profile picker."
  attr :form, :any, required: true

  def override_modal(assigns) do
    assigns = assign(assigns, :custom?, assigns.form[:mode].value == "custom")

    ~H"""
    <div id="smart-space-modal" class="modal modal-open">
      <div class="modal-box max-w-sm">
        <h3 class="font-bold text-lg mb-1">{gettext("Smart Space")}</h3>
        <p class="text-sm text-base-content/60 mb-4">
          {gettext("Move this show's watched seasons or episodes to the trash after a grace period.")}
        </p>
        <.form
          for={@form}
          id="smart-space-override-form"
          phx-change="smart_space_validate"
          phx-submit="smart_space_save"
        >
          <.input
            field={@form[:mode]}
            type="select"
            label={gettext("For this show")}
            options={[
              {gettext("Inherit the global setting"), "inherit"},
              {gettext("Off"), "off"},
              {gettext("Custom"), "custom"}
            ]}
          />
          <div id="smart-space-custom-fields" class={[!@custom? && "hidden"]}>
            <.input
              field={@form[:unit]}
              type="select"
              label={gettext("Clean up")}
              options={[
                {gettext("A season at a time"), "season"},
                {gettext("Episode by episode"), "episode"}
              ]}
            />
            <.input
              field={@form[:grace_days]}
              type="number"
              min="0"
              label={gettext("Days to wait after the last viewer finishes")}
            />
          </div>
          <div class="modal-action">
            <button type="button" phx-click="smart_space_close" class="btn btn-ghost">
              {gettext("Cancel")}
            </button>
            <button type="submit" id="smart-space-save" class="btn btn-primary">
              {gettext("Save")}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="smart_space_close"></div>
    </div>
    """
  end

  @doc "Season header controls: the due badge, then the Keep toggle for season units."
  attr :season_number, :integer, required: true
  attr :smart_space, :map, default: nil

  def season_controls(%{smart_space: nil} = assigns), do: ~H""

  def season_controls(assigns) do
    assigns =
      assigns
      |> assign(:due_at, Map.get(assigns.smart_space.due, {assigns.season_number, nil}))
      |> assign(
        :kept?,
        MapSet.member?(assigns.smart_space.keeps, {:season, assigns.season_number})
      )
      |> assign(
        :season_unit?,
        match?(%{unit: "season"}, assigns.smart_space.rule)
      )

    ~H"""
    <span
      :if={@due_at}
      id={"season-#{@season_number}-smart-space-due"}
      class="badge badge-warning badge-soft gap-1"
    >
      <.icon name="hero-sparkles" class="size-3.5" />
      {due_label(@due_at)}
    </span>
    <.keep_button
      :if={@season_unit? and @smart_space.can_keep?}
      id={"season-#{@season_number}-keep"}
      kept?={@kept?}
      season_number={@season_number}
      label?
      class="btn btn-xs btn-ghost gap-1"
    />
    """
  end

  @doc "Episode row Keep toggle, shown only when the rule's unit is `episode`."
  attr :episode_id, :string, required: true
  attr :season_number, :integer, required: true
  attr :smart_space, :map, default: nil

  def episode_keep(%{smart_space: nil} = assigns), do: ~H""

  def episode_keep(assigns) do
    assigns =
      assigns
      |> assign(
        :due_at,
        Map.get(assigns.smart_space.due, {assigns.season_number, assigns.episode_id})
      )
      |> assign(:kept?, MapSet.member?(assigns.smart_space.keeps, {:episode, assigns.episode_id}))
      |> assign(:show?, episode_unit?(assigns.smart_space) and assigns.smart_space.can_keep?)

    ~H"""
    <.keep_button
      :if={@show?}
      id={"episode-#{@episode_id}-keep"}
      kept?={@kept?}
      title={@due_at && due_label(@due_at)}
      episode_id={@episode_id}
      class="join-item btn btn-sm btn-square btn-ghost"
    />
    """
  end

  attr :id, :string, required: true
  attr :kept?, :boolean, required: true
  attr :class, :string, required: true
  attr :title, :string, default: nil
  attr :season_number, :integer, default: nil
  attr :episode_id, :string, default: nil
  attr :label?, :boolean, default: false

  defp keep_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="smart_space_keep"
      aria-pressed={to_string(@kept?)}
      aria-label={if @kept?, do: gettext("Stop keeping"), else: gettext("Keep")}
      title={@title || if(@kept?, do: gettext("Stop keeping"), else: gettext("Keep"))}
      class={@class}
      phx-value-season-number={@season_number}
      phx-value-episode-id={@episode_id}
    >
      <.icon
        name={if @kept?, do: "hero-lock-closed-solid", else: "hero-lock-open"}
        class={if @kept?, do: "w-4 h-4", else: "w-4 h-4 text-base-content/40"}
      />
      <span :if={@label?} class="text-xs">{gettext("Keep")}</span>
    </button>
    """
  end

  defp episode_unit?(%{rule: %{unit: "episode"}}), do: true
  defp episode_unit?(_smart_space), do: false

  @doc false
  def menu_label(%{override: %{mode: "off"}}), do: gettext("Smart Space: Off")

  def menu_label(%{override: %{mode: "custom"}, rule: rule}),
    do: gettext("Smart Space: Custom (%{rule})", rule: rule_text(rule))

  def menu_label(%{rule: nil}), do: gettext("Smart Space: Inherit (off)")

  def menu_label(%{rule: rule}),
    do: gettext("Smart Space: Inherit (%{rule})", rule: rule_text(rule))

  # An invalid custom row has no effective rule; read it as off.
  defp rule_text(nil), do: gettext("off")

  defp rule_text(%{unit: unit, grace_days: days}) do
    unit_text = if unit == "episode", do: gettext("episode"), else: gettext("season")
    "#{unit_text}, #{ngettext("%{count} day", "%{count} days", days)}"
  end

  @doc "`next run` once eligible, else `Cleans up in N days` rounded up."
  def due_label(eligible_at) do
    seconds = DateTime.diff(eligible_at, DateTime.utc_now())

    if seconds <= 0 do
      gettext("next run")
    else
      days = max(ceil(seconds / 86_400), 1)
      ngettext("Cleans up in %{count} day", "Cleans up in %{count} days", days)
    end
  end
end
