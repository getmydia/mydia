defmodule MydiaWeb.MediaLive.Index.SectionComponents do
  @moduledoc """
  Section-specific chrome for the media index. Used only by the sibling
  LiveView, never imported globally.
  """
  use MydiaWeb, :html

  alias Mydia.Collections.Collection

  attr :section, :map, required: true
  attr :form, :map, required: true
  attr :exclusive_eligible, :boolean, required: true
  attr :open, :boolean, default: false

  def section_settings_modal(assigns) do
    ~H"""
    <div
      :if={@open}
      class="modal modal-open pt-[calc(0.75rem+env(safe-area-inset-top,0px))] pb-[calc(0.75rem+env(safe-area-inset-bottom,0px))] px-3 sm:px-4"
      id="section-settings-modal"
    >
      <div class="modal-box w-full max-h-[calc(100dvh-1.5rem-env(safe-area-inset-top,0px)-env(safe-area-inset-bottom,0px))] sm:max-h-[calc(100dvh-3rem)] flex flex-col overflow-hidden p-4 sm:p-6">
        <h3 class="font-bold text-lg mb-4 shrink-0">{gettext("Section settings")}</h3>

        <.form
          for={@form}
          id="section-settings-form"
          phx-submit="save_section"
          class="flex-1 min-h-0 overflow-y-auto px-1 -mx-1"
        >
          <.input field={@form[:name]} type="text" label={gettext("Name")} />

          <.input
            field={@form[:sidebar_icon]}
            type="select"
            label={gettext("Icon")}
            options={Collection.valid_sidebar_icons()}
          />

          <div :if={@exclusive_eligible} class="form-control mt-4">
            <label class="label cursor-pointer justify-start gap-3">
              <input
                id="section-exclusive-toggle"
                type="checkbox"
                name="section[exclusive]"
                value="true"
                checked={@form[:exclusive].value in [true, "true"]}
                class="toggle toggle-primary"
              />
              <span class="label-text whitespace-normal">
                {gettext("Keep these out of Movies and TV")}
              </span>
            </label>
          </div>

          <div class="modal-action mt-4 pt-3 border-t border-base-300 sticky bottom-0 bg-base-100">
            <button
              id="unpin-section"
              type="button"
              phx-click="unpin_section"
              class="btn btn-ghost text-error"
            >
              {gettext("Remove from sidebar")}
            </button>
            <button type="button" phx-click="close_section_settings" class="btn btn-ghost">
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_section_settings"></div>
    </div>
    """
  end
end
