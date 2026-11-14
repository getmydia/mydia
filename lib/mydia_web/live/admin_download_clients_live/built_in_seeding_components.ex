defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInSeedingComponents do
  @moduledoc """
  The seeding target and speed limit field groups of the built-in client's
  settings modal (`MydiaWeb.AdminDownloadClientsLive.BuiltInFormComponents`).
  """
  use MydiaWeb, :html

  import MydiaWeb.AdminDownloadClientsLive.BuiltInFieldComponents

  attr :form, Phoenix.HTML.Form, required: true
  attr :sources, :map, required: true, doc: "Settings.sources/1; a missing field reads :default"

  def seeding_fields(assigns) do
    ~H"""
    <fieldset
      id="built-in-seeding"
      class="fieldset bg-base-200 border border-base-300 rounded-box p-4 space-y-2"
    >
      <legend class="fieldset-legend">{gettext("Seeding")}</legend>
      <p class="text-sm text-base-content/70">
        {gettext(
          "Leave a target blank to seed forever. A tracker's own minimum always applies on top."
        )}
      </p>
      <.number_row
        form={@form}
        sources={@sources}
        field={:seed_ratio}
        id="built-in-seed-ratio"
        label={gettext("Seed ratio")}
        step="0.1"
      />
      <.number_row
        form={@form}
        sources={@sources}
        field={:seed_time}
        id="built-in-seed-time"
        label={gettext("Seed time (minutes)")}
        step="1"
      />
      <.field_row
        field={:seed_goal_action}
        label={gettext("When a target is reached")}
        sources={@sources}
      >
        <.goal_action form={@form} locked?={locked?(@sources, :seed_goal_action)} />
      </.field_row>
    </fieldset>

    <fieldset
      id="built-in-speed-limits"
      class="fieldset bg-base-200 border border-base-300 rounded-box p-4 space-y-2"
    >
      <legend class="fieldset-legend">{gettext("Speed limits")}</legend>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4">
        <.number_row
          form={@form}
          sources={@sources}
          field={:download_limit}
          id="built-in-download-limit"
          label={gettext("Download limit (KiB/s)")}
          step="1"
        />
        <.number_row
          form={@form}
          sources={@sources}
          field={:upload_limit}
          id="built-in-upload-limit"
          label={gettext("Upload limit (KiB/s)")}
          step="1"
        />
      </div>
      <p class="label whitespace-normal">{gettext("0 or blank for unlimited.")}</p>
    </fieldset>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :sources, :map, required: true
  attr :field, :atom, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :step, :string, required: true

  defp number_row(assigns) do
    ~H"""
    <.field_row field={@field} label={@label} sources={@sources} for={@id}>
      <.input
        field={@form[@field]}
        id={@id}
        type="number"
        min="0"
        step={@step}
        container_class=""
        disabled={locked?(@sources, @field)}
      />
    </.field_row>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :locked?, :boolean, required: true

  defp goal_action(assigns) do
    assigns =
      assigns
      |> assign(:value, to_string(assigns.form[:seed_goal_action].value))
      |> assign(:options, [{"pause", gettext("Pause")}, {"remove", gettext("Remove from client")}])

    ~H"""
    <%= if @locked? do %>
      <p id="built-in-seed-goal-action-locked" class="text-sm">
        {Enum.find_value(@options, @value, fn {v, label} -> if v == @value, do: label end)}
      </p>
    <% else %>
      <.segmented_control
        id="built-in-seed-goal-action"
        value={@value}
        event="validate_built_in"
        param="seed_goal_action"
        label={gettext("When a target is reached")}
      >
        <:option
          :for={{value, label} <- @options}
          id={"built-in-seed-goal-action-#{value}"}
          value={value}
          label={label}
        />
      </.segmented_control>
      <input type="hidden" name={@form[:seed_goal_action].name} value={@value} />
    <% end %>
    """
  end
end
