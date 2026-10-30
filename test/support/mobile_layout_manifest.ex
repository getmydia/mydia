defmodule MydiaWeb.MobileLayoutManifest do
  @moduledoc """
  What the mobile layout sweep visits for each `live` route: the URL (built
  from `MydiaWeb.MobileLayoutSeed` ids) and the interactive states worth
  auditing, or an exclusion with its reason.

  `test/mydia_web/mobile_layout_manifest_test.exs` fails when a route is
  missing, so a new page is swept from its first commit.
  """

  def live_routes do
    MydiaWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug))
    |> Enum.map(& &1.path)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp page(path), do: %{path: fn _ids -> path end, states: []}
  defp page(path, states), do: %{path: fn _ids -> path end, states: states}

  defp error_tracker_exclusion do
    {:exclude, "third-party ErrorTracker dashboard (error_tracker_dashboard), not our layout"}
  end

  def entries do
    %{
      "/" => page("/"),
      "/discover" => page("/discover"),
      "/media/:id" => %{path: &"/media/#{&1.movie}", states: []},
      "/movies" => page("/movies"),
      "/movies/:id" => %{path: &"/movies/#{&1.movie}", states: []},
      "/tv" => page("/tv"),
      "/tv/:id" => %{path: &"/tv/#{&1.show}", states: []},
      "/sections/new" => page("/sections/new"),
      "/sections/:id" => %{path: &"/sections/#{&1.section}", states: []},
      "/import" => page("/import"),
      "/review" => {:exclude, "redirects to /import for old bookmarks; /import is swept"},
      "/search" => page("/search"),
      "/downloads" => page("/downloads", [{"issues", [{:visit_query, "tab=issues"}]}]),
      "/calendar" => page("/calendar"),
      "/activity" => page("/activity"),
      "/collections" => page("/collections"),
      "/collections/:id" => %{path: &"/collections/#{&1.collection}", states: []},
      "/requests" => page("/requests"),
      "/profile" => page("/profile"),
      "/changelog" => page("/changelog"),
      "/integrations" => page("/integrations"),
      "/devices" => page("/devices"),
      "/admin/dashboard" => page("/admin/dashboard"),
      "/admin/status" => page("/admin/status"),
      "/admin/settings" => page("/admin/settings"),
      "/admin/quality" => page("/admin/quality"),
      "/admin/custom-formats" => page("/admin/custom-formats"),
      "/admin/clients" => page("/admin/clients"),
      "/admin/indexers" => page("/admin/indexers"),
      "/admin/subtitle-providers" => page("/admin/subtitle-providers"),
      "/admin/library-paths" => page("/admin/library-paths"),
      "/admin/duplicates" => page("/admin/duplicates"),
      "/admin/trash" => page("/admin/trash"),
      "/admin/media-servers" => page("/admin/media-servers"),
      "/admin/storage-backends" => page("/admin/storage-backends"),
      "/admin/plugins" => page("/admin/plugins"),
      "/admin/path-mappings" => page("/admin/path-mappings"),
      "/admin/remote-access" => page("/admin/remote-access"),
      "/admin/api-keys" => page("/admin/api-keys"),
      "/admin/import-lists" => page("/admin/import-lists"),
      "/admin/jobs" => page("/admin/jobs"),
      "/admin/requests" => page("/admin/requests"),
      "/admin/users" => page("/admin/users"),
      "/admin/release-blacklist" => page("/admin/release-blacklist"),
      "/admin/errors" => error_tracker_exclusion(),
      "/admin/errors/:id" => error_tracker_exclusion(),
      "/admin/errors/:id/:occurrence_id" => error_tracker_exclusion(),
      "/setup" =>
        {:exclude, "renders only before the first admin exists; the sweep logs in as one"},
      "/play/:type/:id" =>
        {:exclude, "full-screen video player chrome, sized to the video, not a page layout"},
      "/plugins/:slug" =>
        {:exclude,
         "needs an enabled wasm plugin that declares a page; plugin frame is sized by the guest"},
      "/plugins/:slug/activity" =>
        {:exclude,
         "needs an enabled wasm plugin that declares a page; plugin frame is sized by the guest"}
    }
  end
end
