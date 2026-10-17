defmodule Mydia.Accounts.Themes.Theme do
  @moduledoc """
  One entry in `Mydia.Accounts.Themes`.

  `id` is the `data-theme` value the CSS keys on. `base` is the theme's
  base-100 colour as hex, used before the stylesheet arrives (launch
  background, `theme-color` meta), so it must match the CSS.
  """
  @enforce_keys [:id, :label, :scheme, :base]
  defstruct [:id, :label, :scheme, :base]

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t(),
          scheme: :light | :dark,
          base: String.t()
        }
end
