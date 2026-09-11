defmodule MydiaWeb.Plugs.RequirePlayer do
  @moduledoc """
  Answers 404 for the player's routes when the player is off
  (`Mydia.Player.enabled?/0`).

  Mounted twice: as the router's `:player` pipeline, and in `MydiaWeb.Endpoint`
  in front of the `/player` static bundle, which is served before the router
  runs. There it is given `only: "/player"`.

  API requests get a body shaped like a GraphQL error, which the player
  already parses. Everything else gets a plain 404.
  """
  @behaviour Plug

  import Plug.Conn

  @body Jason.encode!(%{
          errors: [
            %{
              message: "The player is disabled on this server.",
              extensions: %{code: "PLAYER_DISABLED"}
            }
          ]
        })

  @impl true
  def init(opts) do
    case Keyword.get(opts, :only) do
      nil -> nil
      path -> String.split(path, "/", trim: true)
    end
  end

  @impl true
  def call(conn, prefix) do
    if applies?(conn, prefix) and not Mydia.Player.enabled?() do
      refuse(conn)
    else
      conn
    end
  end

  defp applies?(_conn, nil), do: true
  defp applies?(conn, prefix), do: Enum.take(conn.path_info, length(prefix)) == prefix

  defp refuse(%Plug.Conn{path_info: ["api" | _]} = conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, @body)
    |> halt()
  end

  defp refuse(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
    |> halt()
  end
end
