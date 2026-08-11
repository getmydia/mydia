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
              <%!-- A disabled <button> does not fire hover, so the native title
                   attribute is unreliable there. Wrap it the way the other
                   config pages do and let DaisyUI's .tooltip carry the text. --%>
              <%= if @format.overridden? do %>
                <button
                  id={"custom-format-reset-#{@format.slug}"}
                  class="btn btn-sm btn-ghost join-item"
                  phx-click="reset_custom_format"
                  phx-value-slug={@format.slug}
                  title="Reset to the shipped definition"
                >
                  <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
                </button>
              <% else %>
                <div class="tooltip" data-tip="Not modified">
                  <button
                    id={"custom-format-reset-#{@format.slug}"}
                    class="btn btn-sm btn-ghost join-item"
                    disabled
                  >
                    <.icon name="hero-arrow-uturn-left" class="w-4 h-4 opacity-30" />
                  </button>
                </div>
              <% end %>
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
        <.form
          for={@custom_format_form}
          id="custom-format-form"
          phx-change="validate_custom_format"
          phx-submit="save_custom_format"
        >
          <%!-- Header --%>
          <div class="flex items-center gap-3 mb-5">
            <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
              <.icon
                name={
                  if(@custom_format_mode == :new,
                    do: "hero-plus-circle",
                    else: "hero-pencil-square"
                  )
                }
                class="w-5 h-5 text-primary"
              />
            </div>
            <div>
              <h3 class="font-bold text-lg">
                {if(@custom_format_mode == :new,
                  do: "New Format",
                  else: "Edit #{@editing_custom_format.name}"
                )}
              </h3>
              <p class="text-sm text-base-content/60">
                {if(@custom_format_mode == :new,
                  do: "Match release titles by regex. Scores are set per quality profile.",
                  else: "Update its patterns. Scores are set per quality profile."
                )}
              </p>
            </div>
          </div>

          <div class="space-y-5">
            <div>
              <.input
                field={@custom_format_form[:name]}
                type="text"
                label="Name"
                disabled={@editing_custom_format.builtin?}
              />
              <p :if={@editing_custom_format.builtin?} class="text-xs text-base-content/60 mt-1">
                Built-in names are fixed. Saving stores a local override of the shipped definition.
              </p>
            </div>

            <.input field={@custom_format_form[:description]} type="text" label="Description" />

            <.input
              field={@custom_format_form[:patterns_text]}
              type="textarea"
              label="Patterns (one per line)"
              rows="6"
            />

            <div class="divider text-xs text-base-content/40 my-2">
              Test against a release title
            </div>

            <.input
              field={@custom_format_form[:test_title]}
              id="custom-format-test-input"
              type="text"
              label="Paste a release title"
              placeholder="Film.2024.VFF.1080p.WEB-DL.x264-GROUP"
            />

            <ul :if={@test_results != []} class="space-y-1 text-sm">
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
          </div>

          <%!-- Modal Actions --%>
          <div class="modal-action mt-6 pt-4 border-t border-base-300">
            <button type="button" class="btn btn-ghost" phx-click="close_custom_format_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary gap-2">
              <.icon name="hero-check" class="w-4 h-4" />
              {if(@custom_format_mode == :new, do: "Add Format", else: "Save Changes")}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_custom_format_modal"></div>
    </div>
    """
  end
end
