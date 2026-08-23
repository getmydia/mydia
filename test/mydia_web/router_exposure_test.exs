defmodule MydiaWeb.RouterExposureTest do
  @moduledoc """
  Asserts that every route either passes through a credential-verifying plug or
  appears in the explicit allowlist below.

  A pipeline counts as a guard only if it HALTS the connection when no valid
  credential is present. A pipeline that merely attaches a user (or device)
  when a credential happens to be present, but otherwise passes an anonymous
  request through unchanged, is NOT a guard. `:api_auth` and `:media_api_auth`
  are both of this kind: `MydiaWeb.Plugs.AuthPipeline` loads the resource with
  `Guardian.Plug.LoadResource, allow_blank: true`, and both
  `MydiaWeb.Plugs.ApiAuth` and `MydiaWeb.Plugs.MediaAuth` return the connection
  unchanged when no key/token is present. Only `:require_authenticated` and
  `:require_admin` actually halt.

  The allowlist is a snapshot of routes that are unauthenticated today. Being on
  it means "this is known to be unauthenticated", NOT "this is known to be safe".
  Each entry is dispositioned separately in the security audit.
  """
  use ExUnit.Case, async: true

  # Only pipelines that halt the connection on a missing/invalid credential
  # count as guards. See moduledoc for why :api_auth and :media_api_auth are
  # deliberately excluded.
  @guard_plugs [:require_authenticated, :require_admin]

  # Verbs are matched against Phoenix's own `route.verb`, which is a lowercase
  # atom (:get, :post) -- or `:*` for a `forward`. Matching it directly avoids
  # String.to_atom.
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
    {:get, "/auth/logout"},
    {:*, "/api/graphql"}
  ]

  # Routes whose own path resolves to a *different*, earlier route because of
  # router clause ordering. Each entry is a known shadowing, not an accepted
  # one: `router.ex` defines `get "/:provider"` before `get "/logout"` in the
  # same scope, so Phoenix's top-to-bottom clause matching dispatches a
  # request for /auth/logout via the `/auth/:provider` clause instead. This is
  # harmless today only because both routes share `pipe_through :browser`; if
  # their guard status ever diverged, this test needs to catch it rather than
  # silently trust the wrong route's pipeline. Populate this list only from
  # what an actual run reports -- do not guess.
  @known_route_shadowing [
    {{:get, "/auth/logout"}, "/auth/:provider"}
  ]

  test "every route is guarded or explicitly allowlisted" do
    results = Enum.map(Phoenix.Router.routes(MydiaWeb.Router), &resolve/1)

    assert_no_unexpected_shadowing(results)

    unguarded =
      results
      |> Enum.reject(&guarded?/1)
      |> Enum.map(&elem(&1, 0))
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

  # Resolves a route to `{key, pipe_through, resolved_path}`, where `key` is
  # the route's own `{verb, path}` tuple. `Phoenix.Router.routes/1` (Phoenix
  # 1.8) returns each route as a map with only
  # `[:verb, :path, :plug, :plug_opts, :helper, :metadata]` -- `:pipe_through`
  # is dropped before it reaches `__routes__/0`. `Phoenix.Router.route_info/4`
  # is the public API that still exposes it, but it matches a concrete request
  # path, so dynamic segments are substituted with a placeholder first. It can
  # also resolve to an earlier route's clause (see @known_route_shadowing), so
  # the resolved `:route` is captured and checked too.
  defp resolve(route) do
    key = {route.verb, route.path}
    method = route.verb |> to_string() |> String.upcase()
    path = concrete_path(route.path)

    case Phoenix.Router.route_info(MydiaWeb.Router, method, path, "localhost") do
      %{pipe_through: pipe_through, route: resolved_path} ->
        {key, pipe_through, resolved_path}

      :error ->
        {key, [], route.path}
    end
  end

  defp guarded?({_key, pipe_through, _resolved_path}) do
    Enum.any?(@guard_plugs, &(&1 in pipe_through))
  end

  defp assert_no_unexpected_shadowing(results) do
    unexpected =
      Enum.reject(results, fn {key, _pipe_through, resolved_path} ->
        {_verb, path} = key
        resolved_path == path or {key, resolved_path} in @known_route_shadowing
      end)

    assert unexpected == [],
           """
           Unexpected route shadowing: a route's own path resolves to a
           different, earlier route's clause because of router ordering.

           #{inspect(unexpected)}

           If this is a genuine (if undesirable) shadowing, add it to
           @known_route_shadowing verbatim from this failure; otherwise the
           router needs fixing (out of scope for this snapshot test).
           """
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

  # Maps each halting guard pipeline (see @guard_plugs) to the plug module it
  # is believed to run.
  #
  # The brief for this test originally paired @guard_plugs down to two
  # entries (:require_authenticated, :require_admin) while leaving this map
  # at four keys, then checked membership with
  # `guard_pipelines -- Map.keys(@known_guard_pipelines)`. Since
  # `guard_pipelines` is filtered from `@guard_plugs` itself, it can only ever
  # contain the two atoms already present as keys here -- the subtraction is
  # always `[]` and the assertion can never fail no matter what the pipelines
  # actually contain. That version is not implemented below.
  #
  # What is worth checking: that each pipeline's *body*, not just its name,
  # still invokes the module we believe guards it. Someone could gut
  # `pipeline :require_admin do end` to a no-op while every route's
  # `pipe_through :require_admin` (and this map) stays untouched -- a
  # name-only check would keep passing while every admin route silently
  # stopped being guarded.
  @known_guard_pipelines %{
    require_authenticated: MydiaWeb.Plugs.EnsureAuthenticated,
    require_admin: MydiaWeb.Plugs.EnsureRole
  }

  test "each guard pipeline's body still invokes its known plug module" do
    source = router_source()

    for {pipeline, module} <- @known_guard_pipelines do
      body =
        pipeline_body(source, pipeline) ||
          flunk("pipeline :#{pipeline} not found in router.ex source")

      assert pipeline_invokes?(body, module),
             "pipeline :#{pipeline} no longer invokes #{inspect(module)} -- " <>
               "routes piping through it would silently stop being guarded"
    end
  end

  # Reads the router's own source from the path the compiler recorded for it,
  # rather than a hardcoded path, so this stays correct if the file ever
  # moves.
  #
  # This is a build-time path baked in at compile time: it assumes the
  # process running this test has access to the same source tree the module
  # was compiled from, which holds in this repo's CI (compile and test share
  # a checkout) but would not hold for a release or a `_build`-only Docker
  # layer shipped without the `lib/` source -- `File.read!/1` would raise
  # there. Not a concern for how this suite runs today; noted so a future
  # maintainer moving this test isn't surprised by it.
  defp router_source do
    MydiaWeb.Router.__info__(:compile)
    |> Keyword.fetch!(:source)
    |> List.to_string()
    |> File.read!()
  end

  # Pipeline bodies in router.ex are flat `plug ...` lists with no nested
  # `do`/`end`, so a non-greedy match up to the next `end` correctly bounds
  # the block.
  defp pipeline_body(source, pipeline) do
    case Regex.run(~r/pipeline\s+:#{pipeline}\s+do(.*?)\n\s*end/s, source) do
      [_, body] -> body
      nil -> nil
    end
  end

  # Anchored so a decoy plug whose module name merely starts with the real
  # one (e.g. `MydiaWeb.Plugs.EnsureAuthenticatedButAlwaysAllow`) cannot
  # register as a match: the expected `plug <Module>` text must open the
  # trimmed line and be followed immediately by whitespace, a comma (an
  # options list, e.g. `plug MydiaWeb.Plugs.EnsureRole, :admin`), or nothing
  # else on the line.
  defp pipeline_invokes?(body, module) do
    plug_line = "plug #{inspect(module)}"
    pattern = ~r/^#{Regex.escape(plug_line)}(\s|,|$)/

    body
    |> String.split("\n")
    |> Enum.any?(fn line ->
      trimmed = String.trim(line)
      not String.starts_with?(trimmed, "#") and Regex.match?(pattern, trimmed)
    end)
  end
end
