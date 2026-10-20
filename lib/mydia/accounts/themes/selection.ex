defmodule Mydia.Accounts.Themes.Selection do
  @moduledoc """
  A user's resolved theme choice: the mode, the theme for each scheme and the
  corner roundness.

  Always holds catalogue themes and a listed radius, never raw values, so
  callers never need to handle an unknown one. Build it with
  `Mydia.Accounts.Themes.selection/4`.
  """
  alias Mydia.Accounts.Themes.Theme

  @enforce_keys [:mode, :light, :dark, :radius]
  defstruct [:mode, :light, :dark, :radius]

  @type t :: %__MODULE__{
          mode: String.t(),
          light: Theme.t(),
          dark: Theme.t(),
          radius: String.t()
        }
end
