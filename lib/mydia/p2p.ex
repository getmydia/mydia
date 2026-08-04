defmodule Mydia.P2p do
  @moduledoc """
  NIF bindings for iroh-based p2p networking.

  This module provides the Elixir interface to the Rust-based p2p networking
  functionality using iroh. The core networking is implemented in Rust for
  performance and protocol correctness.
  """
  use Rustler, otp_app: :mydia, crate: "mydia_p2p"

  @doc """
  Start the p2p host with configuration.

  ## Options
    * `:relay_url` - Custom relay URL for NAT traversal (uses iroh default relays if nil).
    * `:bind_port` - UDP port for direct connections (enables hole punching in Docker).
      If nil or 0, a random port is used.
    * `:keypair_path` - Path to store/load the node's keypair for persistent identity.
      If nil, a new random keypair is generated on each start.

  Returns `{:ok, {resource, node_id}}` on success.
  """
  def start_host(_relay_url \\ nil, _bind_port \\ nil, _keypair_path \\ nil),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Dial a peer using their EndpointAddr JSON.
  The endpoint_addr_json should be a JSON-serialized EndpointAddr.
  """
  def dial(_resource, _endpoint_addr_json), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Get this node's EndpointAddr as JSON for sharing with other peers.
  """
  def get_node_addr(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Start listening for p2p events.
  Events will be sent as messages to the given process.
  """
  def start_listening(_resource, _pid), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Send a response to an incoming request.
  """
  def send_response(_resource, _request_id, _response), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Get network statistics including connected peers and relay status.
  """
  def get_network_stats(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Send an HLS response header for a streaming request.
  Must be called before any send_hls_chunk calls.
  """
  def send_hls_header(_resource, _stream_id, _header), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Send a chunk of HLS data.
  Must be called after send_hls_header and before finish_hls_stream.
  """
  def send_hls_chunk(_resource, _stream_id, _data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Finish an HLS stream.
  Must be called after all chunks have been sent.
  """
  def finish_hls_stream(_resource, _stream_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Stream a file range directly to a QUIC stream.
  Reads the file in Rust and writes length-prefixed chunks, avoiding per-chunk NIF overhead.
  The stream is finished automatically after all data is written.
  """
  def stream_file_range(_resource, _stream_id, _file_path, _offset, _length),
    do: :erlang.nif_error(:nif_not_loaded)
end

defmodule Mydia.P2p.PairingRequest do
  @moduledoc """
  A pairing request received from a player.
  """
  defstruct [:claim_code, :device_name, :device_type, :device_os]

  @type t :: %__MODULE__{
          claim_code: String.t(),
          device_name: String.t(),
          device_type: String.t(),
          device_os: String.t() | nil
        }
end

defmodule Mydia.P2p.PairingResponse do
  @moduledoc """
  A pairing response to send back to a player.
  """
  defstruct [:success, :media_token, :access_token, :device_token, :error, direct_urls: []]

  @type t :: %__MODULE__{
          success: boolean(),
          media_token: String.t() | nil,
          access_token: String.t() | nil,
          device_token: String.t() | nil,
          error: String.t() | nil,
          direct_urls: [String.t()]
        }
end

defmodule Mydia.P2p.NetworkStats do
  @moduledoc """
  Network statistics from the p2p host.
  """
  defstruct [:connected_peers, :relay_connected, :relay_url, :peer_connection_type]

  @type t :: %__MODULE__{
          connected_peers: non_neg_integer(),
          relay_connected: boolean(),
          relay_url: String.t() | nil,
          peer_connection_type: String.t()
        }
end

defmodule Mydia.P2p.GraphQLRequest do
  @moduledoc """
  A GraphQL request received from a player over P2P.
  """
  defstruct [:query, :variables, :operation_name, :auth_token]

  @type t :: %__MODULE__{
          query: String.t(),
          variables: String.t() | nil,
          operation_name: String.t() | nil,
          auth_token: String.t() | nil
        }
end

defmodule Mydia.P2p.GraphQLResponse do
  @moduledoc """
  A GraphQL response to send back to a player over P2P.
  """
  defstruct [:data, :errors]

  @type t :: %__MODULE__{
          data: String.t() | nil,
          errors: String.t() | nil
        }
end

defmodule Mydia.P2p.HlsRequest do
  @moduledoc """
  An HLS streaming request received from a player over P2P.
  """
  defstruct [:session_id, :path, :range_start, :range_end, :auth_token]

  @type t :: %__MODULE__{
          session_id: String.t(),
          path: String.t(),
          range_start: non_neg_integer() | nil,
          range_end: non_neg_integer() | nil,
          auth_token: String.t() | nil
        }
end

defmodule Mydia.P2p.HlsResponseHeader do
  @moduledoc """
  An HLS response header to send back to a player over P2P.
  """
  defstruct [:status, :content_type, :content_length, :content_range, :cache_control]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          content_type: String.t(),
          content_length: non_neg_integer(),
          content_range: String.t() | nil,
          cache_control: String.t() | nil
        }
end
