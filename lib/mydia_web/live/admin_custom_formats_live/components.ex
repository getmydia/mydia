defmodule MydiaWeb.AdminCustomFormatsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  Renders the Custom Formats tab content.
  """
  attr :formats, :list, required: true

  def custom_formats_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Custom Formats</h1>
          <p class="text-sm opacity-70">
            Match release titles by regex. Assign scores per quality profile.
          </p>
        </div>
        <.button id="custom-format-new" phx-click="new_custom_format" class="btn-primary">
          <.icon name="hero-plus" class="w-4 h-4" /> New format
        </.button>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body p-0 divide-y divide-base-200">
          <div
            :for={format <- @formats}
            id={"custom-format-row-#{format.slug}"}
            class="flex items-center gap-3 p-4"
          >
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="font-medium">{format.name}</span>
                <span :if={format.builtin?} class="badge badge-sm badge-ghost">Built-in</span>
                <span :if={format.overridden?} class="badge badge-sm badge-warning">Edited</span>
              </div>
              <div class="text-xs opacity-60 truncate font-mono">
                {Enum.join(format.patterns, "  ")}
              </div>
            </div>

            <.button
              id={"custom-format-edit-#{format.slug}"}
              phx-click="edit_custom_format"
              phx-value-slug={format.slug}
              class="btn-sm btn-ghost"
            >
              Edit
            </.button>

            <.button
              :if={format.overridden?}
              id={"custom-format-reset-#{format.slug}"}
              phx-click="reset_custom_format"
              phx-value-slug={format.slug}
              class="btn-sm btn-ghost"
            >
              Reset
            </.button>

            <.button
              :if={not format.builtin?}
              id={"custom-format-delete-#{format.slug}"}
              phx-click="delete_custom_format"
              phx-value-slug={format.slug}
              data-confirm={"Delete #{format.name}?"}
              class="btn-sm btn-ghost text-error"
            >
              Delete
            </.button>
          </div>
        </div>
      </div>
    </div>
    """
  end

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
