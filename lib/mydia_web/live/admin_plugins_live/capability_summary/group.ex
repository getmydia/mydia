defmodule MydiaWeb.AdminPluginsLive.CapabilitySummary.Group do
  @moduledoc "A titled group of capability summary lines (Talks to, Can see, ...)."

  alias MydiaWeb.AdminPluginsLive.CapabilitySummary.Line

  @enforce_keys [:key, :title]
  defstruct [:key, :title, emphasized?: false, lines: []]

  @type key :: :talks_to | :can_see | :can_change | :adds
  @type t :: %__MODULE__{
          key: key(),
          title: String.t(),
          emphasized?: boolean(),
          lines: [Line.t()]
        }
end
