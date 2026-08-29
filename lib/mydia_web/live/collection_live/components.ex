defmodule MydiaWeb.CollectionLive.Components do
  @moduledoc """
  Components shared by the collection index and show LiveViews.

  The smart rules condition editor is rendered both by the create-collection
  dialog and by the edit-rules dialog of an existing collection. It lives here
  rather than in `MydiaWeb.CollectionComponents` because only these two
  sibling LiveViews use it.
  """

  use MydiaWeb, :html

  alias Mydia.Collections.SmartRulesFields

  # Smart rules editor component
  attr :conditions, :list, required: true
  attr :match_type, :string, required: true
  attr :sort_field, :string, required: true
  attr :sort_direction, :string, required: true
  attr :limit, :any, required: true
  attr :value_options, :map, required: true

  def smart_rules_editor(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- Conditions Card --%>
      <div class="card bg-base-200/50 border border-base-300">
        <div class="card-body p-4">
          <%!-- Header with match type and add button --%>
          <div class="flex items-center justify-between mb-3">
            <div class="flex items-center gap-3">
              <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-secondary/20">
                <.icon name="hero-funnel" class="w-4 h-4 text-secondary" />
              </div>
              <div class="flex items-center gap-2">
                <span class="text-sm font-medium">Match</span>
                <select name="match_type" class="select select-sm select-bordered bg-base-100">
                  <option value="all" selected={@match_type == "all"}>all conditions</option>
                  <option value="any" selected={@match_type == "any"}>any condition</option>
                </select>
              </div>
            </div>
            <button
              type="button"
              phx-click="add_condition"
              class="btn btn-sm btn-secondary btn-outline gap-1"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> Add
            </button>
          </div>

          <%!-- Conditions List --%>
          <div class="space-y-2">
            <%= for {condition, index} <- Enum.with_index(@conditions) do %>
              <div class="flex items-center gap-2 p-3 bg-base-100 rounded-lg border border-base-300 shadow-sm">
                <%!-- Condition number badge --%>
                <div class="badge badge-sm badge-ghost font-mono w-6 h-6 flex-shrink-0">
                  {index + 1}
                </div>

                <%!-- Field selector --%>
                <select
                  name={"conditions[#{index}][field]"}
                  class="select select-sm select-bordered flex-1 min-w-0 bg-base-100"
                >
                  <option value="">Select field...</option>
                  <optgroup label="Basic">
                    <option value="category" selected={condition["field"] == "category"}>
                      Category
                    </option>
                    <option value="type" selected={condition["field"] == "type"}>Type</option>
                    <option value="year" selected={condition["field"] == "year"}>Year</option>
                    <option value="title" selected={condition["field"] == "title"}>Title</option>
                    <option value="monitored" selected={condition["field"] == "monitored"}>
                      Monitored
                    </option>
                  </optgroup>
                  <optgroup label="Metadata">
                    <option
                      value="metadata.vote_average"
                      selected={condition["field"] == "metadata.vote_average"}
                    >
                      Rating
                    </option>
                    <option value="metadata.genres" selected={condition["field"] == "metadata.genres"}>
                      Genre
                    </option>
                    <option
                      value="metadata.original_language"
                      selected={condition["field"] == "metadata.original_language"}
                    >
                      Language
                    </option>
                    <option value="metadata.status" selected={condition["field"] == "metadata.status"}>
                      Status
                    </option>
                  </optgroup>
                  <optgroup label="Dates">
                    <option value="inserted_at" selected={condition["field"] == "inserted_at"}>
                      Date Added
                    </option>
                  </optgroup>
                </select>

                <%!-- Operator selector --%>
                <.condition_operator_select
                  field={condition["field"]}
                  operator={condition["operator"]}
                  index={index}
                />

                <%!-- Value input --%>
                <.condition_value_input
                  field={condition["field"]}
                  operator={condition["operator"]}
                  value={condition["value"]}
                  value_options={@value_options}
                  index={index}
                />

                <%!-- Remove button --%>
                <button
                  type="button"
                  phx-click="remove_condition"
                  phx-value-index={index}
                  class={[
                    "btn btn-ghost btn-sm btn-square text-base-content/50 hover:text-error hover:bg-error/10",
                    length(@conditions) <= 1 && "btn-disabled opacity-30"
                  ]}
                  title="Remove condition"
                  disabled={length(@conditions) <= 1}
                >
                  <.icon name="hero-trash" class="w-4 h-4" />
                </button>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Sort & Limit Card --%>
      <div class="card bg-base-200/50 border border-base-300">
        <div class="card-body p-4">
          <div class="flex items-center gap-3 mb-3">
            <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-primary/20">
              <.icon name="hero-arrows-up-down" class="w-4 h-4 text-primary" />
            </div>
            <span class="text-sm font-medium">Sort & Limit</span>
            <span class="text-xs text-base-content/50">(Optional)</span>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <%!-- Sort by --%>
            <div class="form-control">
              <label class="label py-1">
                <span class="label-text text-xs">Sort by</span>
              </label>
              <select name="sort_field" class="select select-sm select-bordered bg-base-100 w-full">
                <option value="" selected={@sort_field == ""}>Default order</option>
                <option value="title" selected={@sort_field == "title"}>Title</option>
                <option value="year" selected={@sort_field == "year"}>Year</option>
                <option value="rating" selected={@sort_field == "rating"}>Rating</option>
                <option value="added_date" selected={@sort_field == "added_date"}>Date Added</option>
              </select>
            </div>

            <%!-- Direction --%>
            <div class="form-control">
              <label class="label py-1">
                <span class="label-text text-xs">Direction</span>
              </label>
              <select
                name="sort_direction"
                class="select select-sm select-bordered bg-base-100 w-full"
              >
                <option value="asc" selected={@sort_direction == "asc"}>Ascending</option>
                <option value="desc" selected={@sort_direction == "desc"}>Descending</option>
              </select>
            </div>

            <%!-- Limit --%>
            <div class="form-control">
              <label class="label py-1">
                <span class="label-text text-xs">Max items</span>
              </label>
              <input
                type="number"
                name="limit"
                min="0"
                max="1000"
                placeholder="No limit"
                value={@limit}
                class="input input-sm input-bordered bg-base-100 w-full"
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp value_placeholder("in"), do: "value1, value2, ..."
  defp value_placeholder("not_in"), do: "value1, value2, ..."
  defp value_placeholder("contains_any"), do: "value1, value2, ..."
  defp value_placeholder("between"), do: "min, max"
  defp value_placeholder(_), do: "Value..."

  # Condition operator selector - data-driven from SmartRulesFields
  attr :field, :string, required: true
  attr :operator, :string, required: true
  attr :index, :integer, required: true

  defp condition_operator_select(assigns) do
    operators = SmartRulesFields.get_operators(assigns.field)
    labels = SmartRulesFields.operator_labels()

    # Special labels for date fields
    date_labels =
      if assigns.field == "inserted_at" do
        %{gt: "after", gte: "on or after", lt: "before", lte: "on or before"}
      else
        %{}
      end

    assigns =
      assigns
      |> assign(:operators, operators)
      |> assign(:labels, Map.merge(labels, date_labels))

    ~H"""
    <select
      name={"conditions[#{@index}][operator]"}
      class="select select-sm select-bordered w-32 bg-base-100"
    >
      <%= for op <- @operators do %>
        <option value={op} selected={@operator == to_string(op)}>
          {Map.get(@labels, op, to_string(op))}
        </option>
      <% end %>
    </select>
    """
  end

  # Condition value input - data-driven from SmartRulesFields
  attr :field, :string, required: true
  attr :operator, :string, required: true
  attr :value, :any, required: true
  attr :value_options, :map, required: true
  attr :index, :integer, required: true

  defp condition_value_input(assigns) do
    field_def = SmartRulesFields.get_field(assigns.field)
    render_value_input(assigns, field_def)
  end

  # Enum fields - options are loaded once when the dialog opens, never in render
  defp render_value_input(assigns, %{type: :enum}) do
    assigns = assign(assigns, :options, Map.get(assigns.value_options, assigns.field, []))

    ~H"""
    <select
      name={"conditions[#{@index}][value]"}
      class="select select-sm select-bordered flex-1 min-w-0 bg-base-100"
    >
      <option value="">Select...</option>
      <%= for {val, label} <- @options do %>
        <option value={val} selected={@value == val or @value == to_string(val)}>{label}</option>
      <% end %>
    </select>
    """
  end

  # Boolean fields - render yes/no dropdown
  defp render_value_input(assigns, %{type: :boolean}) do
    assigns = assign(assigns, :options, Map.get(assigns.value_options, assigns.field, []))

    ~H"""
    <select
      name={"conditions[#{@index}][value]"}
      class="select select-sm select-bordered flex-1 min-w-0 bg-base-100"
    >
      <option value="">Select...</option>
      <%= for {val, label} <- @options do %>
        <option value={val} selected={@value == val or @value == to_string(val)}>{label}</option>
      <% end %>
    </select>
    """
  end

  # Number fields with "between" operator - render text input for range
  defp render_value_input(%{operator: "between"} = assigns, %{type: :number} = field_def) do
    placeholder =
      if field_def[:input_opts][:step] do
        "e.g. 7.0, 9.0"
      else
        "e.g. 2000, 2024"
      end

    assigns = assign(assigns, :placeholder, placeholder)

    ~H"""
    <input
      type="text"
      name={"conditions[#{@index}][value]"}
      value={@value}
      class="input input-sm input-bordered flex-1 min-w-0 bg-base-100"
      placeholder={@placeholder}
    />
    """
  end

  # Number fields - render number input
  defp render_value_input(assigns, %{type: :number} = field_def) do
    opts = Map.get(field_def, :input_opts, %{})

    assigns =
      assigns
      |> assign(:min, Map.get(opts, :min, 1900))
      |> assign(:max, Map.get(opts, :max, 2100))
      |> assign(:step, Map.get(opts, :step, 1))

    ~H"""
    <input
      type="number"
      name={"conditions[#{@index}][value]"}
      value={@value}
      min={@min}
      max={@max}
      step={@step}
      class="input input-sm input-bordered flex-1 min-w-0 bg-base-100"
    />
    """
  end

  # Date fields - render date input
  defp render_value_input(assigns, %{type: :date}) do
    assigns = assign(assigns, :formatted_value, format_date_value(assigns.value))

    ~H"""
    <input
      type="date"
      name={"conditions[#{@index}][value]"}
      value={@formatted_value}
      class="input input-sm input-bordered flex-1 min-w-0 bg-base-100"
    />
    """
  end

  # Text fields and fallback - render text input
  defp render_value_input(assigns, _field_def) do
    ~H"""
    <input
      type="text"
      name={"conditions[#{@index}][value]"}
      value={@value}
      class="input input-sm input-bordered flex-1 min-w-0 bg-base-100"
      placeholder={value_placeholder(@operator)}
    />
    """
  end

  defp format_date_value(nil), do: ""
  defp format_date_value(""), do: ""

  defp format_date_value(value) when is_binary(value) do
    if String.match?(value, ~r/^\d{4}-\d{2}-\d{2}/) do
      String.slice(value, 0, 10)
    else
      value
    end
  end

  defp format_date_value(_), do: ""
end
