defmodule MetadataRelayWeb.Router do
  use Phoenix.Router
  use ErrorTracker.Web, :router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import MetadataRelayWeb.DashboardAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {MetadataRelayWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :authed_dashboard do
    plug(:require_dashboard_auth)
  end

  scope "/auth", MetadataRelayWeb do
    pipe_through(:browser)

    get("/login", AuthController, :login)
    get("/github", AuthController, :request)
    get("/github/callback", AuthController, :callback)
    post("/logout", AuthController, :logout)
  end

  # Maintainer dashboards
  scope "/" do
    pipe_through([:browser, :authed_dashboard])

    error_tracker_dashboard("/errors",
      on_mount: [{MetadataRelayWeb.DashboardAuth, :require_github_login}]
    )

    live_session :feedback,
      on_mount: [{MetadataRelayWeb.DashboardAuth, :require_github_login}],
      session: {MetadataRelayWeb.DashboardAuth, :live_session_data, []} do
      live("/feedback", MetadataRelayWeb.FeedbackLive.Index, :index)
    end
  end

  # Forward all other requests to the API router
  forward("/", MetadataRelay.Router)
end
