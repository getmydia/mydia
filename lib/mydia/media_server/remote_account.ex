defmodule Mydia.MediaServer.RemoteAccount do
  @moduledoc """
  One user account as the media server itself reports it.

  Plex and Jellyfin describe accounts with different field names, and the
  mapping UI has to offer both from the same list, so both adapters are
  normalised into this struct. The `id` is the identity the link stores in
  `remote_user_id`: a Plex Home account id, or a Jellyfin user GUID.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          admin?: boolean()
        }

  defstruct [:id, :name, admin?: false]

  @doc """
  Display name for an account, falling back to its id.

  Jellyfin and Plex both allow accounts whose name is missing from the API
  response, and an unlabelled row in a picker is worse than a raw id.
  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def label(%__MODULE__{id: id}), do: to_string(id)
end
