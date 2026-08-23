defmodule MydiaWeb.RouterExposureTest do
  @moduledoc """
  Asserts that every route either passes through a credential-verifying plug or
  appears in the explicit allowlist below.

  The allowlist is a snapshot of routes that are unauthenticated today. Being on
  it means "this is known to be unauthenticated", NOT "this is known to be safe".
  Each entry is dispositioned separately in the security audit.
  """
  use ExUnit.Case, async: true

  # Plugs that establish or require a verified identity.
  @guard_plugs [
    :require_authenticated,
    :require_admin,
    :api_auth,
    :media_api_auth
  ]

  # Verbs are matched against Phoenix's own `route.verb`, which is a lowercase
  # atom (:get, :post). Matching it directly avoids String.to_atom.
  @unauthenticated_allowlist [
    {:get, "/health"},
    {:get, "/setup"},
    {:get, "/auth/login"},
    {:get, "/auth/local/login"},
    {:post, "/auth/local/login"},
    {:get, "/auth/auto-login"},
    {:get, "/auth/:provider"},
    {:get, "/auth/:provider/callback"},
    {:post, "/auth/:provider/callback"},
    {:get, "/auth/logout"}
  ]

  test "every route is guarded or explicitly allowlisted" do
    unguarded =
      MydiaWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.reject(&guarded?/1)
      |> Enum.map(&{&1.verb, &1.path})
      |> Enum.uniq()

    assert Enum.sort(unguarded) == Enum.sort(@unauthenticated_allowlist),
           """
           The set of unauthenticated routes changed.

           Newly unauthenticated: #{inspect(unguarded -- @unauthenticated_allowlist)}
           No longer present:     #{inspect(@unauthenticated_allowlist -- unguarded)}

           If you intentionally added an unauthenticated route, add it to
           @unauthenticated_allowlist and disposition it in the security audit.
           """
  end

  defp guarded?(route) do
    Enum.any?(@guard_plugs, &(&1 in pipe_through(route)))
  end

  # Phoenix.Router.routes/1 (Phoenix 1.8) returns each route as a map with only
  # `[:verb, :path, :plug, :plug_opts, :helper, :metadata]` -- `:pipe_through`
  # is compiled into the internal %Phoenix.Router.Route{} struct but dropped
  # before it reaches `__routes__/0`. Phoenix.Router.route_info/4 is the public
  # API that still exposes it, but it matches against a concrete request path,
  # so dynamic segments are substituted with a placeholder first.
  defp pipe_through(route) do
    method = route.verb |> to_string() |> String.upcase()
    path = concrete_path(route.path)

    case Phoenix.Router.route_info(MydiaWeb.Router, method, path, "localhost") do
      %{pipe_through: pipe_through} -> pipe_through
      :error -> []
    end
  end

  defp concrete_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _ -> "placeholder"
      "*" <> _ -> "placeholder"
      segment -> segment
    end)
  end
end
