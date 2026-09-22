defmodule MetadataRelayWeb.Router do
  use Phoenix.Router
  use ErrorTracker.Web, :router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {MetadataRelayWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :authed_dashboard do
    plug(:dashboard_basic_auth)
  end

  # Plain-text player logs for curl and agents (`./dev relay logs`). Not in
  # :browser, whose accepts(["html"]) would refuse a text/plain request.
  scope "/" do
    pipe_through([:authed_dashboard])
    get("/logs/raw", MetadataRelayWeb.LogsRawController, :show)
  end

  # Maintainer dashboards
  scope "/" do
    pipe_through([:browser, :authed_dashboard])
    error_tracker_dashboard("/errors")
    live("/feedback", MetadataRelayWeb.FeedbackLive.Index, :index)
  end

  # Forward all other requests to the API router
  forward("/", MetadataRelay.Router)

  defp dashboard_basic_auth(conn, _opts) do
    Plug.BasicAuth.basic_auth(
      conn,
      Keyword.merge(
        [realm: "Metadata Relay Dashboard"],
        Application.fetch_env!(:metadata_relay, :dashboard_auth)
      )
    )
  end
end
