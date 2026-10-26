defmodule MydiaWeb.AdminNav.Page do
  @moduledoc """
  One admin page in `MydiaWeb.AdminNav`.

  The translated label and description come from `MydiaWeb.AdminNav.page_label/1`
  and `page_description/1`.

  `requires` names the feature gate that hides the page: `:player`
  (`Mydia.Player.enabled?/0`). It stays an atom so the struct is plain data;
  `MydiaWeb.AdminNav.visible?/1` interprets it.
  """

  @type hub :: :configuration | :administration | :system

  @type t :: %__MODULE__{
          key: atom(),
          hub: hub(),
          icon: String.t(),
          path: String.t(),
          requires: nil | :player
        }

  @enforce_keys [:key, :hub, :icon, :path]
  defstruct [:key, :hub, :icon, :path, requires: nil]
end
