defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInSeedingComponents do
  @moduledoc """
  The seeding target field group of the built-in client's
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
          "Torrents keep seeding until a target below is reached. With both blank they seed forever; set a ratio of 0 to stop as soon as the download finishes. A tracker's own minimum always applies on top."
        )}
      </p>
      <%!-- A number input's default step of 1 would make browsers reject 1.5. --%>
      <.text_field
        form={@form}
        field={:seed_ratio}
        sources={@sources}
        inputmode="decimal"
        placeholder={gettext("Blank: seed forever")}
        label={gettext("Seed ratio")}
      />
      <.text_field
        form={@form}
        field={:seed_time}
        sources={@sources}
        type="number"
        placeholder={gettext("Blank: seed forever")}
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
    """
  end
end
