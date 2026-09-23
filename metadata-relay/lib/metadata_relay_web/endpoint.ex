defmodule MetadataRelayWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :metadata_relay

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_metadata_relay_key",
    signing_salt: "error_tracker_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Serve at "/" the static files from "priv/static" directory.
  plug(Plug.Static,
    at: "/",
    from: :metadata_relay,
    gzip: false,
    only: ~w(css js assets fonts images favicon.ico robots.txt)
  )

  # After Plug.Static on purpose: static assets keep Plug.Static's own
  # cache headers. See the moduledoc for why this is endpoint-wide.
  plug(MetadataRelayWeb.Plug.PrivateByDefault)

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  # CORS support for browser-based clients
  plug(Corsica,
    origins: "*",
    allow_headers: ["content-type", "authorization", "x-request-id"],
    allow_methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
  )

  plug(MetadataRelayWeb.Router)
end
