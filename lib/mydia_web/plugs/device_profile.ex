defmodule MydiaWeb.Plugs.DeviceProfile do
  @moduledoc """
  Parses the `X-Mydia-Device-Profile` header into `conn.assigns[:device_profile]`.

  The header holds base64url-encoded JSON describing what the caller can decode.
  It is read on every request rather than stored against a device, because a
  stored profile goes stale the moment the viewer changes OS, display, or
  hardware decode availability.

  Anything malformed or over the caps is treated as an absent profile, not as an
  error. A client that cannot encode its capabilities should still be able to
  watch something, and every consumer already has a defined no-profile answer.
  """
  @behaviour Plug

  alias Mydia.Streaming.DeviceProfile

  @header "x-mydia-device-profile"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Plug.Conn.assign(conn, :device_profile, parse(conn))
  end

  defp parse(conn) do
    case Plug.Conn.get_req_header(conn, @header) do
      [value | _] -> DeviceProfile.decode_header(value)
      [] -> nil
    end
  end
end
