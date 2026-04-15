defmodule Web.Router do
  use Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Web do
    pipe_through :browser

    live "/", DashboardLive, :index
  end

  scope "/api/v1", Web do
    pipe_through :api

    get "/state", ObservabilityApiController, :state
    post "/refresh", ObservabilityApiController, :refresh
    get "/:issue_identifier", ObservabilityApiController, :issue
    match :*, "/state", ObservabilityApiController, :method_not_allowed
    match :*, "/refresh", ObservabilityApiController, :method_not_allowed
    match :*, "/:issue_identifier", ObservabilityApiController, :method_not_allowed
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:hortator, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: Web.Telemetry
    end
  end
end
