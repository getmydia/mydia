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
    <div :if={@open} class="modal modal-open" id="section-settings-modal">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Section settings</h3>

        <.form for={@form} id="section-settings-form" phx-submit="save_section">
          <.input field={@form[:name]} type="text" label="Name" />

          <.input
            field={@form[:sidebar_icon]}
            type="select"
            label="Icon"
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
              <span class="label-text">
                Keep these out of Movies and TV
              </span>
            </label>
          </div>

          <div class="modal-action">
            <button
              id="unpin-section"
              type="button"
              phx-click="unpin_section"
              class="btn btn-ghost text-error"
            >
              Remove from sidebar
            </button>
            <button type="button" phx-click="close_section_settings" class="btn btn-ghost">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_section_settings"></div>
    </div>
    """
  end
end
