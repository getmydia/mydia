defmodule MydiaWeb.ProfileLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  A preference select whose blank option means "inherit the server default".

  Every add-option preference is tri-state: a value, or absent meaning inherit.
  A checkbox cannot express the third state, so even the boolean fields are
  selects.
  """
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true, doc: "list of {value, label} tuples"

  def inherit_select(assigns) do
    ~H"""
    <label class="form-control">
      <span class="label-text">{@label}</span>
      <select name={@name} class="select select-bordered select-sm">
        <option value="">Use server default</option>
        <option
          :for={{value, label} <- @options}
          value={to_string(value)}
          selected={@value == value}
        >
          {label}
        </option>
      </select>
    </label>
    """
  end
end
