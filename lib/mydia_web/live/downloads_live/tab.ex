defmodule MydiaWeb.DownloadsLive.Tab do
  @moduledoc """
  One entry in the Downloads page tab bar, rendered by
  `MydiaWeb.DownloadsLive.ListComponents.tab_bar/1`.

  `tone: :error` paints a non-zero count red (Issues). `dot?` adds the
  stalled-download status dot (Downloads).
  """

  @enforce_keys [:key, :label, :icon, :href]
  defstruct [:key, :label, :icon, :href, count: 0, tone: :neutral, dot?: false]

  @type t :: %__MODULE__{
          key: :downloads | :issues | :external,
          label: String.t(),
          icon: String.t(),
          href: String.t(),
          count: non_neg_integer(),
          tone: :neutral | :error,
          dot?: boolean()
        }
end
