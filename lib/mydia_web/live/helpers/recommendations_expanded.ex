defmodule MydiaWeb.Live.Helpers.RecommendationsExpanded do
  @moduledoc """
  Reads and persists whether the More Like This rail on a media detail page is
  open.

  Modelled on `MydiaWeb.Live.Helpers.GridDensity`, which solves the same
  problem for the shared poster-grid density. The rail used to reset to
  collapsed on every mount, so a user who wanted it open had to reopen it on
  every page load.

  A guest or unauthenticated render has no preference row to read: it gets the
  default, and its toggle clicks change the current view without being
  persisted.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  @assign :recommendations_expanded

  @doc """
  Assigns the viewer's stored value, or the default when there is no user.
  """
  def assign_current(socket) do
    assign(socket, @assign, current(socket))
  end

  @doc """
  The viewer's stored value, or the default when there is no user.
  """
  def current(socket) do
    case socket.assigns[:current_user] do
      nil -> UserPreference.defaults()["recommendations_expanded"]
      user -> user |> Accounts.get_user_preference!() |> UserPreference.recommendations_expanded()
    end
  end

  @doc """
  Persists the value for the viewer and reassigns it.

  A rejected changeset leaves the stored value alone and flashes, rather than
  silently showing a rail state that will not survive a reload.
  """
  def put(socket, expanded) when is_boolean(expanded) do
    case socket.assigns[:current_user] do
      nil ->
        assign(socket, @assign, expanded)

      user ->
        preference = Accounts.get_user_preference!(user)

        case Accounts.update_preference(preference, %{"recommendations_expanded" => expanded}) do
          {:ok, _} -> assign(socket, @assign, expanded)
          {:error, _changeset} -> put_flash(socket, :error, "Could not save that rail state")
        end
    end
  end
end
