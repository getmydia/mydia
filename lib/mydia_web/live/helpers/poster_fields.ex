defmodule MydiaWeb.Live.Helpers.PosterFields do
  @moduledoc """
  Reads and persists the library poster fields preference
  (`Mydia.Accounts.PosterFields`). A guest or unauthenticated render gets the
  defaults, and its changes apply to the current view without being
  persisted.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Accounts
  alias Mydia.Accounts.PosterFields
  alias Mydia.Accounts.UserPreference

  @assign :poster_fields

  def assign_current(socket), do: assign(socket, @assign, current(socket))

  def current(socket) do
    case socket.assigns[:current_user] do
      nil -> PosterFields.default_keys()
      user -> user |> Accounts.get_user_preference!() |> UserPreference.poster_fields()
    end
  end

  @doc """
  Persists the checked fields. `fields` are the raw strings from the form;
  unknown strings are dropped before saving, so a stale tab cannot fail the
  save with a key a newer release removed.
  """
  def put(socket, fields) when is_list(fields) do
    keys = PosterFields.resolve(fields)

    case socket.assigns[:current_user] do
      nil ->
        assign(socket, @assign, keys)

      user ->
        preference = Accounts.get_user_preference!(user)
        stored = Enum.map(keys, &Atom.to_string/1)

        case Accounts.update_preference(preference, %{"poster_fields" => stored}) do
          {:ok, _} -> assign(socket, @assign, keys)
          {:error, _} -> put_flash(socket, :error, "Could not save poster display settings")
        end
    end
  end
end
