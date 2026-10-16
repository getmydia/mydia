defmodule MydiaWeb.DownloadsLive.Filters do
  @moduledoc """
  The Downloads page's search and filter state, parsed from URL params by
  `MydiaWeb.DownloadsLive.ListView.parse_filters/2`.
  """

  defstruct q: nil, client: nil, status: nil

  @type t :: %__MODULE__{
          q: String.t() | nil,
          client: String.t() | nil,
          status: String.t() | nil
        }
end
