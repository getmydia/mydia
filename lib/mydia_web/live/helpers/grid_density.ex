defmodule MydiaWeb.Live.Helpers.GridDensity do
  @moduledoc """
  Reads and persists the shared poster-grid density preference for the
  Discover and Libraries LiveViews.

  Both pages read the same preference key, so the read and the write live
  here rather than being copied into each LiveView. An unauthenticated or
  guest render has no preference row to read: it gets the default, and its
  toggle clicks change the current view without being persisted.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  @assign :grid_density

  @doc """
  Assigns the viewer's stored density, or the default when there is no user.
  """
  def assign_current(socket) do
    assign(socket, @assign, current(socket))
  end

  @doc """
  The viewer's stored density, or the default when there is no user.
  """
  def current(socket) do
    case socket.assigns[:current_user] do
      nil -> UserPreference.defaults()["grid_density"]
      user -> user |> Accounts.get_user_preference!() |> UserPreference.grid_density()
    end
  end

  @doc """
  Persists a density for the viewer and reassigns it.

  A rejected changeset leaves the stored preference alone and flashes, rather
  than silently showing a density that will not survive a reload.
  """
  def put(socket, density) do
    case socket.assigns[:current_user] do
      nil ->
        assign(socket, @assign, density)

      user ->
        preference = Accounts.get_user_preference!(user)

        case Accounts.update_preference(preference, %{"grid_density" => density}) do
          {:ok, _} -> assign(socket, @assign, density)
          {:error, _changeset} -> put_flash(socket, :error, "Could not save that grid density")
        end
    end
  end
end
