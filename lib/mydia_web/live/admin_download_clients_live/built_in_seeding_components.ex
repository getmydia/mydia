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
      <%!-- A number input's default step of 1 would make browsers reject 1.5. --%>
      <.text_field
        form={@form}
        field={:seed_ratio}
        sources={@sources}
        inputmode="decimal"
        label={gettext("Seed ratio")}
      />
      <.text_field
        form={@form}
        field={:seed_time}
        sources={@sources}
        type="number"
        label={gettext("Seed time (minutes)")}
      />
      <.field_row
        field={:seed_goal_action}
        label={gettext("When a target is reached")}
        sources={@sources}
      >
        <.choice
          form={@form}
          field={:seed_goal_action}
          locked?={locked?(@sources, :seed_goal_action)}
          label={gettext("When a target is reached")}
          options={[{"pause", gettext("Pause")}, {"remove", gettext("Remove from client")}]}
        />
        <:hint>
          {gettext(
            "Remove also applies to imported torrents already in the client, including ones you resumed by hand: those past the target are removed with their files on the next check."
          )}
        </:hint>
      </.field_row>
    </fieldset>

    <fieldset
      id="built-in-speed-limits"
      class="fieldset bg-base-200 border border-base-300 rounded-box p-4 space-y-2"
    >
      <legend class="fieldset-legend">{gettext("Speed limits")}</legend>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4">
        <.text_field
          form={@form}
          field={:download_limit}
          sources={@sources}
          type="number"
          label={gettext("Download limit (KiB/s)")}
        />
        <.text_field
          form={@form}
          field={:upload_limit}
          sources={@sources}
          type="number"
          label={gettext("Upload limit (KiB/s)")}
        />
      </div>
      <p class="label whitespace-normal">{gettext("0 or blank for unlimited.")}</p>
    </fieldset>
    """
  end
end
