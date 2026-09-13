defmodule MydiaWeb.AdminNav.Page do
  @moduledoc """
  One admin page in `MydiaWeb.AdminNav`.

  `requires` names the feature gate that hides the page: `:player`
  (`Mydia.Player.enabled?/0`) or `:import_lists`
  (`Mydia.ImportLists.FeatureFlags.enabled?/0`). It stays an atom so the struct
  is plain data; `MydiaWeb.AdminNav.visible?/1` interprets it.
  """

  @type hub :: :configuration | :administration | :system

  @type t :: %__MODULE__{
          key: atom(),
          hub: hub(),
          label: String.t(),
          description: String.t(),
          icon: String.t(),
          path: String.t(),
          requires: nil | :player | :import_lists
        }

  @enforce_keys [:key, :hub, :label, :description, :icon, :path]
  defstruct [:key, :hub, :label, :description, :icon, :path, requires: nil]
end
