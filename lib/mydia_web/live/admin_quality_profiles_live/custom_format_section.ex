defmodule MydiaWeb.AdminQualityProfilesLive.CustomFormatSection do
  @moduledoc """
  Custom format score assignment inside the quality profile editor.

  Definitions are global and edited on the Custom Formats admin page. This
  section only assigns what each format is worth to one profile.

  Lives in its own module because the sibling `components.ex` is already well
  past the project's ~500 LOC per component file guidance.
  """
  use MydiaWeb, :html

  attr :formats, :list, required: true
  attr :assignments, :map, required: true, doc: "slug => %{score: integer, reject: boolean}"

  def custom_format_section(assigns) do
    ~H"""
    <div id="profile-custom-formats" class="space-y-2">
      <div>
        <h3 class="font-semibold">Custom Formats</h3>
        <p class="text-sm opacity-70">
          Score releases by what their title contains. A rejected format is never grabbed.
          Define formats on the
          <.link navigate={~p"/admin/config/custom-formats"} class="link">
            Custom Formats
          </.link>
          page.
        </p>
      </div>

      <div class="space-y-1">
        <div
          :for={format <- @formats}
          class="flex items-center gap-3 py-1"
        >
          <div class="flex-1 min-w-0">
            <span class="font-medium">{format.name}</span>
            <span class="text-xs opacity-60 ml-2 truncate">{format.description}</span>
          </div>

          <input
            type="number"
            id={"custom-format-score-#{format.slug}"}
            name={"custom_formats[#{format.slug}][score]"}
            value={assignment(@assignments, format.slug).score}
            class="input input-bordered input-sm w-24"
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
            <span class="label-text">Reject</span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  defp assignment(assignments, slug) do
    Map.get(assignments, slug, %{score: 0, reject: false})
  end
end
