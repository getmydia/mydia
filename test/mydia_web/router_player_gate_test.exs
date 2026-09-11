defmodule MydiaWeb.RouterPlayerGateTest do
  use ExUnit.Case, async: true

  # Every route whose only client is a player, or whose handler needs a process
  # under Mydia.Player.Supervisor.
  @player_prefixes [
    "/player",
    "/api/graphql",
    "/api/graphiql",
    "/api/v1/stream",
    "/api/v1/hls",
    "/api/v1/playback",
    "/api/v1/download",
    "/api/player"
  ]

  @player_paths [
    "/api/v1/media/:id/thumbnails.vtt",
    "/api/v1/media/:id/thumbnails.jpg"
  ]

  defp player_route?(%{path: path}) do
    path in @player_paths or
      Enum.any?(@player_prefixes, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  # Phoenix.Router.__routes__/0 does not carry :pipe_through on the route
  # struct (it is only computed for the compiled dispatch clauses). The
  # documented way to recover it for a given route is a live match via
  # Phoenix.Router.route_info/4, which returns it in the metadata map. The
  # placeholder segments in a route's own :path (":id", "*path") match their
  # own compiled variable/glob patterns, so this works for every route shape,
  # including forwards (verb: :*).
  defp pipe_through(route) do
    verb = route.verb |> to_string() |> String.upcase()

    case Phoenix.Router.route_info(MydiaWeb.Router, verb, route.path, "example.com") do
      %{pipe_through: pipe_through} -> pipe_through
      :error -> []
    end
  end

  test "every player route is behind the :player pipeline" do
    routes = Enum.filter(MydiaWeb.Router.__routes__(), &player_route?/1)

    # The lists above must match something, or this test proves nothing.
    assert length(routes) >= 20

    for route <- routes do
      assert :player in pipe_through(route),
             "#{route.verb} #{route.path} is a player route without the :player pipeline"
    end
  end

  test "no other route is behind it" do
    for route <- MydiaWeb.Router.__routes__(), :player in pipe_through(route) do
      assert player_route?(route),
             "#{route.verb} #{route.path} is gated but not listed as a player route"
    end
  end
end
