defmodule MydiaWeb.AdminPluginsLive.CapabilitySummary.Line do
  @moduledoc "One host-owned line of a capability summary."

  @enforce_keys [:label]
  defstruct [:label, new?: false]

  @type t :: %__MODULE__{label: String.t(), new?: boolean()}
end
