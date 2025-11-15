defmodule Mydia.Downloads.Structs.ClientInfo do
  @moduledoc """
  Represents connection information returned by a download client's test_connection/1 function.

  This struct provides compile-time safety for client version information across all
  download clients (qBittorrent, Transmission, SABnzbd, NZBGet), replacing plain map
  access that can silently return nil.

  Different clients use different field names for their API version:
  - qBittorrent, SABnzbd, NZBGet: use `api_version`
  - Transmission: uses `rpc_version`

  Both field names are supported for compatibility.
  """

  @enforce_keys [:version]

  defstruct [
    :version,
    :api_version,
    :rpc_version
  ]

  @type t :: %__MODULE__{
          version: String.t(),
          api_version: String.t() | integer() | nil,
          rpc_version: String.t() | integer() | nil
        }

  @doc """
  Creates a new ClientInfo struct from a map or keyword list.

  Supports both `api_version` and `rpc_version` field names for compatibility
  with different download clients.

  ## Examples

      iex> new(version: "v4.5.0", api_version: "2.8.19")
      %ClientInfo{
        version: "v4.5.0",
        api_version: "2.8.19",
        rpc_version: nil
      }

      iex> new(version: "3.00", rpc_version: 16)
      %ClientInfo{
        version: "3.00",
        api_version: nil,
        rpc_version: 16
      }
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct(__MODULE__, attrs)
  end
end
