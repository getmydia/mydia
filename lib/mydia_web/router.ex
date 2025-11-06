defmodule MydiaWeb.Router do
  use MydiaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MydiaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Authentication pipeline - verifies JWT tokens from session or header
  pipeline :auth do
    plug MydiaWeb.Plugs.AuthPipeline
  end

  # Require authenticated user
  pipeline :require_authenticated do
    plug MydiaWeb.Plugs.EnsureAuthenticated
  end

  # Require admin role
  pipeline :require_admin do
    plug MydiaWeb.Plugs.EnsureRole, :admin
  end

  # API authentication pipeline - supports both JWT and API keys
  pipeline :api_auth do
    plug MydiaWeb.Plugs.AuthPipeline
    plug MydiaWeb.Plugs.ApiAuth
  end

  # Health check endpoint (no authentication required)
  scope "/", MydiaWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end

  # Authentication routes
  scope "/auth", MydiaWeb do
    pipe_through :browser

    # Local authentication (development only)
    get "/login", SessionController, :new
    get "/local/login", SessionController, :new
    post "/local/login", SessionController, :create

    # OIDC authentication
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    post "/:provider/callback", AuthController, :callback

    # Logout
    get "/logout", AuthController, :logout
  end

  # Authenticated LiveView routes
  scope "/", MydiaWeb do
    pipe_through [:browser, :auth, :require_authenticated]

    live_session :authenticated,
      on_mount: [{MydiaWeb.Live.UserAuth, :ensure_authenticated}] do
      live "/", DashboardLive.Index, :index
      live "/media", MediaLive.Index, :index
      live "/media/:id", MediaLive.Show, :show
      live "/movies", MediaLive.Index, :movies
      live "/movies/:id", MediaLive.Show, :show
      live "/tv", MediaLive.Index, :tv_shows
      live "/tv/:id", MediaLive.Show, :show
      live "/add/movie", AddMediaLive.Index, :add_movie
      live "/add/series", AddMediaLive.Index, :add_series
      live "/import", ImportMediaLive.Index, :index
      live "/search", SearchLive.Index, :index
      live "/downloads", DownloadsLive.Index, :index
      live "/calendar", CalendarLive.Index, :index
    end
  end

  # Admin LiveView routes
  scope "/admin", MydiaWeb do
    pipe_through [:browser, :auth, :require_authenticated, :require_admin]

    live_session :admin,
      on_mount: [{MydiaWeb.Live.UserAuth, :ensure_authenticated}] do
      live "/", AdminStatusLive.Index, :index
      live "/status", AdminStatusLive.Index, :index
      live "/config", AdminConfigLive.Index, :index
      live "/jobs", JobsLive.Index, :index
    end
  end

  # API routes - authenticated with JWT or API key
  scope "/api/v1", MydiaWeb.Api do
    pipe_through [:api, :api_auth, :require_authenticated]

    # Download clients
    get "/downloads/clients", DownloadClientController, :index
    get "/downloads/clients/:id", DownloadClientController, :show
    post "/downloads/clients/:id/test", DownloadClientController, :test
    post "/downloads/clients/refresh", DownloadClientController, :refresh

    # Indexers
    get "/indexers", IndexerController, :index
    get "/indexers/:id", IndexerController, :show
    post "/indexers/:id/test", IndexerController, :test
    post "/indexers/:id/reset-failures", IndexerController, :reset_failures
    post "/indexers/refresh", IndexerController, :refresh

    # Media items
    get "/media/:id", MediaController, :show
    post "/media/:id/match", MediaController, :match
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:mydia, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MydiaWeb.Telemetry
    end
  end
end
