defmodule Mydia.Metadata.Structs.WatchProvider do
  @moduledoc """
  A streaming service TMDB lists for a region (data from JustWatch).

  `display_priority` is the region's own ordering when TMDB supplies one in
  `display_priorities`, else the global value. Lower sorts first.
  """

  @enforce_keys [:id, :name]
  defstruct [:id, :name, :logo_path, display_priority: 9_999]

  @type t :: %__MODULE__{
          id: pos_integer(),
          name: String.t(),
          logo_path: String.t() | nil,
          display_priority: integer()
        }

  @doc "Builds a provider from a TMDB result, or nil when it has no usable id or name."
  @spec from_api(map(), String.t()) :: t() | nil
  def from_api(%{"provider_id" => id, "provider_name" => name} = data, region)
      when is_integer(id) and id > 0 and is_binary(name) and name != "" do
    priority =
      get_in(data, ["display_priorities", region]) || data["display_priority"] || 9_999

    %__MODULE__{id: id, name: name, logo_path: data["logo_path"], display_priority: priority}
  end

  def from_api(_data, _region), do: nil
end
