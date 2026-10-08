defmodule MydiaWeb.AdminCustomFormatsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  Renders the Custom Formats tab content.
  """
  attr :custom_formats, :list, required: true

  def custom_formats_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <.admin_list id="custom-formats" items={@custom_formats}>
        <:row :let={format}>
          <.custom_format_row format={format} />
        </:row>
        <:empty>No custom formats yet.</:empty>
      </.admin_list>
    </div>
    """
  end

  @doc "The page header's New button."
  def header_actions(assigns) do
    ~H"""
    <button id="custom-format-new" class="btn btn-sm btn-primary" phx-click="new_custom_format">
      <.icon name="hero-plus" class="w-4 h-4" /> New
    </button>
    """
  end

  attr :format, :map, required: true

  defp custom_format_row(assigns) do
    ~H"""
    <.admin_row id={"custom-format-row-#{@format.slug}"}>
      <:title>{@format.name}</:title>
      <:descriptor><span class="font-mono">{row_descriptor(@format)}</span></:descriptor>
      <:badges>
        <span :if={@format.builtin?} class="badge badge-sm badge-outline">Built-in</span>
        <span :if={@format.overridden?} class="badge badge-sm badge-outline badge-warning">
          Edited
        </span>
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            id={"custom-format-edit-#{@format.slug}"}
            icon="hero-pencil"
            title="Edit"
            phx-click="edit_custom_format"
            phx-value-slug={@format.slug}
          />
          <.row_action
            :if={@format.builtin?}
            id={"custom-format-reset-#{@format.slug}"}
            icon="hero-arrow-uturn-left"
            title="Reset to the shipped definition"
            disabled={not @format.overridden?}
            disabled_reason={if(not @format.overridden?, do: "Not modified")}
            phx-click="reset_custom_format"
            phx-value-slug={@format.slug}
          />
          <.row_action
            :if={not @format.builtin?}
            id={"custom-format-delete-#{@format.slug}"}
            icon="hero-trash"
            title="Delete"
            destructive
            phx-click="delete_custom_format"
            phx-value-slug={@format.slug}
            data-confirm={"Delete #{@format.name}?"}
          />
        </.row_actions>
      </:actions>
    </.admin_row>
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
  attr :custom_format_test_results, :list, default: []

  def custom_format_modal(assigns) do
    ~H"""
    <.admin_modal
      id="custom-format-modal"
      icon={if(@custom_format_mode == :new, do: "hero-plus-circle", else: "hero-pencil-square")}
      title={
        if(@custom_format_mode == :new,
          do: "New Format",
          else: "Edit #{@editing_custom_format.name}"
        )
      }
      subtitle={
        if(@custom_format_mode == :new,
          do: "Match release titles by regex. Scores are set per quality profile.",
          else: "Update its patterns. Scores are set per quality profile."
        )
      }
      on_close="close_custom_format_modal"
    >
      <.form
        for={@custom_format_form}
        id="custom-format-form"
        phx-change="validate_custom_format"
        phx-submit="save_custom_format"
      >
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

          <ul :if={@custom_format_test_results != []} class="space-y-1 text-sm">
            <li :for={r <- @custom_format_test_results} class="flex items-center gap-2 font-mono">
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

        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_custom_format_modal">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary gap-2">
            <.icon name="hero-check" class="w-4 h-4" />
            {if(@custom_format_mode == :new, do: "Add Format", else: "Save Changes")}
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end
end
