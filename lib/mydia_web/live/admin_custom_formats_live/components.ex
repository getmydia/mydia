defmodule MydiaWeb.AdminCustomFormatsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  Renders the Custom Formats tab content.
  """
  attr :formats, :list, required: true

  def custom_formats_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-language" class="w-5 h-5 opacity-60" /> Custom Formats
          <span class="badge badge-ghost">{length(@formats)}</span>
        </h2>
        <button id="custom-format-new" class="btn btn-sm btn-primary" phx-click="new_custom_format">
          <.icon name="hero-plus" class="w-4 h-4" /> New
        </button>
      </div>

      <div class="bg-base-200 rounded-box divide-y divide-base-300">
        <.custom_format_row :for={format <- @formats} format={format} />
      </div>
    </div>
    """
  end

  attr :format, :map, required: true

  defp custom_format_row(assigns) do
    ~H"""
    <div id={"custom-format-row-#{@format.slug}"} class="p-3 sm:p-4">
      <div class="flex flex-col sm:flex-row sm:items-center gap-3">
        <div class="flex-1 min-w-0">
          <div class="font-semibold">{@format.name}</div>
          <div class="text-xs opacity-60 font-mono truncate mt-0.5">{row_descriptor(@format)}</div>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <span :if={@format.builtin?} class="badge badge-sm badge-outline">Built-in</span>
          <span :if={@format.overridden?} class="badge badge-sm badge-warning">Edited</span>

          <div class="join ml-auto sm:ml-2">
            <button
              id={"custom-format-edit-#{@format.slug}"}
              class="btn btn-sm btn-ghost join-item"
              phx-click="edit_custom_format"
              phx-value-slug={@format.slug}
              title="Edit"
            >
              <.icon name="hero-pencil" class="w-4 h-4" />
            </button>
            <%= if @format.builtin? do %>
              <button
                id={"custom-format-reset-#{@format.slug}"}
                class="btn btn-sm btn-ghost join-item"
                phx-click="reset_custom_format"
                phx-value-slug={@format.slug}
                disabled={not @format.overridden?}
                title={
                  if(@format.overridden?,
                    do: "Reset to the shipped definition",
                    else: "Not modified"
                  )
                }
              >
                <.icon
                  name="hero-arrow-uturn-left"
                  class={["w-4 h-4", not @format.overridden? && "opacity-30"]}
                />
              </button>
            <% else %>
              <button
                id={"custom-format-delete-#{@format.slug}"}
                class="btn btn-sm btn-ghost join-item text-error"
                phx-click="delete_custom_format"
                phx-value-slug={@format.slug}
                data-confirm={"Delete #{@format.name}?"}
                title="Delete"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Formats normally show their patterns. A format with none would otherwise
  # render a blank second line, so fall back to the description.
  defp row_descriptor(%{patterns: []} = format), do: format.description || "No patterns"
  defp row_descriptor(format), do: Enum.join(format.patterns, "  ")

  @doc """
  Renders the Custom Format modal.
  """
  attr :custom_format_form, :any, required: true
  attr :custom_format_mode, :atom, required: true
  attr :editing_custom_format, :any, required: true
  attr :test_results, :list, default: []

  def custom_format_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">
          {if(@custom_format_mode == :new,
            do: "New format",
            else: "Edit #{@editing_custom_format.name}"
          )}
        </h3>

        <.form
          for={@custom_format_form}
          id="custom-format-form"
          phx-change="validate_custom_format"
          phx-submit="save_custom_format"
        >
          <.input
            field={@custom_format_form[:name]}
            type="text"
            label="Name"
            disabled={@editing_custom_format.builtin?}
          />
          <.input field={@custom_format_form[:description]} type="text" label="Description" />
          <.input
            field={@custom_format_form[:patterns_text]}
            type="textarea"
            label="Patterns (one per line)"
            rows="6"
          />

          <div class="divider">Test</div>

          <.input
            field={@custom_format_form[:test_title]}
            id="custom-format-test-input"
            type="text"
            label="Paste a release title"
            placeholder="Film.2024.VFF.1080p.WEB-DL.x264-GROUP"
          />

          <ul :if={@test_results != []} class="mt-2 space-y-1 text-sm">
            <li :for={r <- @test_results} class="flex items-center gap-2 font-mono">
              <span :if={r.status == :match} class="custom-format-test-match text-success">
                <.icon name="hero-check-circle" class="w-4 h-4" />
              </span>
              <span :if={r.status == :miss} class="opacity-40">
                <.icon name="hero-x-circle" class="w-4 h-4" />
              </span>
              <span :if={match?({:error, _}, r.status)} class="text-error">
                <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
              </span>
              <span>{r.pattern}</span>
            </li>
          </ul>

          <div class="modal-action">
            <.button type="button" phx-click="close_custom_format_modal" class="btn-ghost">
              Cancel
            </.button>
            <.button type="submit" class="btn-primary">Save</.button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_custom_format_modal"></div>
    </div>
    """
  end
end
