defmodule MydiaWeb.AdminIndexersLive.LoginFlow do
  @moduledoc """
  The interactive Cardigann login on the Indexers page, as LiveView hooks so the
  large `AdminIndexersLive.Index` gains only one line of wiring.

  The pending `Challenge` (cookie jar included) lives only in this socket's assigns.
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Mydia.Indexers
  alias Mydia.Indexers.Cardigann.{Login, SessionManager}
  alias Mydia.Indexers.CardigannParser

  @begin :indexer_login_begin
  @complete :indexer_login_complete

  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Mydia.PubSub, SessionManager.topic())

    socket
    |> assign(login_challenge: nil, login_definition: nil, login_error: nil, login_busy: false)
    |> attach_hook(:indexer_login_events, :handle_event, &handle_event/3)
    |> attach_hook(:indexer_login_async, :handle_async, &handle_async/3)
    |> attach_hook(:indexer_login_info, :handle_info, &handle_info/2)
  end

  defp handle_event("indexer_login", %{"id" => id}, socket) do
    definition = Indexers.get_cardigann_definition!(id)
    {:halt, socket |> assign(login_definition: definition, login_error: nil) |> begin()}
  end

  defp handle_event("indexer_login_refresh", _params, socket),
    do: {:halt, socket |> assign(login_error: nil) |> begin()}

  defp handle_event("indexer_login_submit", %{"login" => answers}, socket) do
    challenge = socket.assigns.login_challenge

    {:halt,
     socket
     |> assign(login_busy: true)
     |> start_async(@complete, fn -> Login.complete(challenge, answers) end)}
  end

  defp handle_event("indexer_login_close", _params, socket) do
    {:halt,
     socket
     |> cancel_async(@begin)
     |> cancel_async(@complete)
     |> reset()}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # The modal was closed while the request ran: drop the late result.
  defp handle_async(name, _result, %{assigns: %{login_definition: nil}} = socket)
       when name in [@begin, @complete],
       do: {:halt, socket}

  # A rejected answer: a fresh attempt gives a new image and keeps the modal open.
  defp handle_async(@complete, {:ok, {:error, error}}, socket),
    do: {:halt, socket |> assign(login_error: error_message(error)) |> begin()}

  defp handle_async(name, {:ok, result}, socket) when name in [@begin, @complete],
    do: {:halt, handle_result(socket, result)}

  defp handle_async(name, {:exit, _reason}, socket) when name in [@begin, @complete] do
    {:halt,
     assign(socket,
       login_busy: false,
       login_error: gettext("The login request failed. Try again.")
     )}
  end

  defp handle_async(_name, _result, socket), do: {:cont, socket}

  defp handle_info({:cardigann_health_changed, _id}, socket) do
    send(self(), :reload_library_indexers)
    {:halt, socket}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  defp begin(socket) do
    definition = socket.assigns.login_definition

    socket
    |> assign(login_busy: true)
    |> start_async(@begin, fn ->
      with {:ok, parsed} <- CardigannParser.parse_definition(definition.definition) do
        Login.begin(parsed, definition)
      end
    end)
  end

  defp handle_result(socket, {:ok, session}) do
    # store/2 clears needs_login from the database row; the struct only names it.
    definition = socket.assigns.login_definition
    SessionManager.store(definition, session)
    send(self(), :reload_library_indexers)

    socket |> reset() |> put_flash(:info, gettext("Logged in to %{name}", name: definition.name))
  end

  defp handle_result(socket, {:needs_input, challenge}),
    do: assign(socket, login_challenge: challenge, login_busy: false)

  # No challenge yet: the login failed before there was anything to answer.
  defp handle_result(%{assigns: %{login_challenge: nil}} = socket, {:error, error}),
    do: socket |> reset() |> put_flash(:error, error_message(error))

  defp handle_result(socket, {:error, error}),
    do: assign(socket, login_busy: false, login_error: error_message(error))

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_), do: gettext("Could not read this indexer's definition")

  defp reset(socket),
    do:
      assign(socket,
        login_challenge: nil,
        login_definition: nil,
        login_error: nil,
        login_busy: false
      )
end
