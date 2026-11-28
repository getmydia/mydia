defmodule Mydia.Downloads.Queue.PreparedAdd do
  @moduledoc """
  The first half of a client add, ready to hand to the client: the fetched
  torrent or NZB input, the settled download type and options, and the chosen
  client with its adapter. Built by `ClientSelection.prepare/2` and
  `FilePreview.confirm/2`.
  """

  @enforce_keys [:torrent_input_result, :opts, :client_config, :adapter]
  defstruct [:torrent_input_result, :download_type, :opts, :client_config, :adapter]

  @type t :: %__MODULE__{
          torrent_input_result: term(),
          download_type: atom() | nil,
          opts: keyword(),
          client_config: map(),
          adapter: module()
        }
end
