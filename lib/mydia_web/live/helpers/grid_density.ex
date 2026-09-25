defmodule MydiaWeb.Live.Helpers.GridDensity do
  @moduledoc """
  Reads and sets the poster-grid density for the Discover and Libraries
  LiveViews.

  Density is a per-browser setting, not an account preference, so a
  desktop's choice never reaches the same account's phone (#700). The
  browser holds it in the `mydia_grid_density` cookie:

    * `MydiaWeb.Plugs.GridDensityCookie` copies the cookie into the session
      on every HTTP request, and `assign_current/2` reads it from there.
    * `put/2` pushes `grid_density:saved`, and the `GridDensity` JS hook
      writes the cookie only then, so the browser stores only values the
      server accepted.

  The session is fixed when the LiveView socket connects, so after a change
  a live navigation to the other page mounts with the old value. The hook
  compares the cookie with the rendered toggle on mount and re-sends
  `set_grid_density` when they differ.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias MydiaWeb.GridDensityComponents

  @assign :grid_density

  @doc """
  Assigns this browser's density from the session, or the default.
  """
  def assign_current(socket, session) do
    assign(socket, @assign, current(session))
  end

  @doc """
  This browser's density from the session, or the default.
  """
  def current(%{"grid_density" => density}) do
    if GridDensityComponents.valid?(density),
      do: density,
      else: GridDensityComponents.default()
  end

  def current(_session), do: GridDensityComponents.default()

  @doc """
  Applies a density to the current view and asks the browser to keep it.
  An unknown value is ignored.
  """
  def put(socket, density) do
    if GridDensityComponents.valid?(density) do
      socket
      |> assign(@assign, density)
      |> push_event("grid_density:saved", %{density: density})
    else
      socket
    end
  end
end
