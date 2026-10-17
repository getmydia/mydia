defmodule Mydia.Accounts.Themes.Selection do
  @moduledoc """
  A user's resolved theme choice: the mode plus the theme for each scheme.

  Always holds catalogue themes, never raw ids, so callers never need to
  handle an unknown id. Build it with `Mydia.Accounts.Themes.selection/3`.
  """
  alias Mydia.Accounts.Themes.Theme

  @enforce_keys [:mode, :light, :dark]
  defstruct [:mode, :light, :dark]

  @type t :: %__MODULE__{mode: String.t(), light: Theme.t(), dark: Theme.t()}
end
