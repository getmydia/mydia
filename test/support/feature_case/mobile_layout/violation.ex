defmodule MydiaWeb.FeatureCase.MobileLayout.Violation do
  @moduledoc """
  One layout defect found by `MydiaWeb.FeatureCase.MobileLayout.audit/1`.

  `route` is the router pattern (`/media/:id`), not the visited URL, so an
  exception survives a change of seeded id. `state` names the manifest state
  the page was in, or nil for the page as loaded.
  """
  @enforce_keys [:check, :selector, :detail]
  defstruct [:route, :width, :state, :check, :selector, :detail]

  @type t :: %__MODULE__{
          route: String.t() | nil,
          width: pos_integer() | nil,
          state: String.t() | nil,
          check: atom(),
          selector: String.t(),
          detail: String.t()
        }
end
