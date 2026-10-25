defmodule MydiaWeb.AdminQualityProfilesLive.CustomFormatSection do
  @moduledoc """
  Custom format score assignment inside the quality profile editor.

  Definitions are global and edited on the Custom Formats admin page. This
  section only assigns what each format is worth to one profile.

  Lives in its own module to keep the editor modal in `modal_components.ex`
  under the project's ~500 LOC per component file guidance.
  """
  use MydiaWeb, :html

  attr :formats, :list, required: true
  attr :assignments, :map, required: true, doc: "slug => %{score: integer, reject: boolean}"

  # A collapsible section (#1189): the format list is long and most profiles
  # leave it alone. It starts open when the profile already scores or rejects
  # something, so a configured profile never hides its settings. Inputs in a
  # closed <details> still submit. `ignore_attributes` keeps the user's
  # open/closed choice across the phx-change re-renders the form triggers.
  #
  # Each row stacks the name over its description, and the score and reject
  # controls wrap below them when the modal is phone-narrow instead of
  # pushing past its edge.
  def custom_format_section(assigns) do
    assigns =
      assign(
        assigns,
        :configured?,
        Enum.any?(Map.values(assigns.assignments), &(&1.score != 0 or &1.reject))
      )

    ~H"""
    <details
      id="profile-custom-formats"
      class="collapse collapse-arrow border border-base-300 mt-4"
      open={@configured?}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="collapse-title font-semibold">{gettext("Custom Formats")}</summary>
      <div class="collapse-content space-y-2">
        <p class="text-sm opacity-70">
          {gettext("Score releases by what their title contains. A rejected format is never grabbed.")}
          {gettext("Define formats on the")}
          <.link navigate={~p"/admin/custom-formats"} class="link">
            {gettext("Custom Formats")}
          </.link>
          {gettext("page.")}
        </p>

        <div class="divide-y divide-base-200">
          <div
            :for={format <- @formats}
            class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2"
          >
            <div class="flex-1 min-w-48">
              <div class="font-medium">{format.name}</div>
              <div class="text-xs opacity-60 line-clamp-2" title={format.description}>
                {format.description}
              </div>
            </div>

            <div class="flex items-center gap-3 shrink-0">
              <input
                type="number"
                id={"custom-format-score-#{format.slug}"}
                name={"custom_formats[#{format.slug}][score]"}
                value={assignment(@assignments, format.slug).score}
                class="input input-bordered input-sm w-24"
                aria-label={gettext("%{name} score", name: format.name)}
              />

              <label class="label cursor-pointer gap-2">
                <input type="hidden" name={"custom_formats[#{format.slug}][reject]"} value="false" />
                <input
                  type="checkbox"
                  id={"custom-format-reject-#{format.slug}"}
                  name={"custom_formats[#{format.slug}][reject]"}
                  value="true"
                  checked={assignment(@assignments, format.slug).reject}
                  class="checkbox checkbox-sm checkbox-error"
                />
                <span class="label-text">{gettext("Reject")}</span>
              </label>
            </div>
          </div>
        </div>
      </div>
    </details>
    """
  end

  defp assignment(assignments, slug) do
    Map.get(assignments, slug, %{score: 0, reject: false})
  end
end
