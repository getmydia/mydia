import { createBrowserRouter } from "react-router-dom";
import { RequireAuth, RequireAdmin } from "./lib/auth";
import { AppShell } from "./layouts/app-shell";
import { AdminConfigShell } from "./layouts/admin-config-shell";
import { LoginPage } from "./pages/login";
import { DashboardPage } from "./pages/dashboard";
import { CalendarPage } from "./pages/calendar";
import { DiscoverPage } from "./pages/discover";
import { SearchPage } from "./pages/search";
import { AddMediaPage } from "./pages/add-media";
import { ImportMediaPage } from "./pages/import-media";
import { MediaDetailPage } from "./pages/media-detail";
import { MoviesPage } from "./pages/movies";
import { TvShowsPage } from "./pages/tv-shows";
import { CollectionsPage } from "./pages/collections";
import { PlaybackPage } from "./pages/playback";
import { MyRequestsPage } from "./pages/my-requests";
import { RequestMediaPage } from "./pages/request-media";
import { ProfilePage } from "./pages/profile";
import { ActivityPage } from "./pages/admin/activity";
import { DownloadsPage } from "./pages/admin/downloads";
import { UsersPage } from "./pages/admin/users";
import { ImportListsPage } from "./pages/admin/import-lists";
import { JobsPage } from "./pages/admin/jobs";
import { ReleaseBlacklistPage } from "./pages/admin/release-blacklist";
import { RequestsPage } from "./pages/admin/requests";
import { SystemPage } from "./pages/admin/system";
import { SettingsPage } from "./pages/admin/settings";
import { QualityProfilesPage } from "./pages/admin/quality-profiles";
import { DownloadClientsPage } from "./pages/admin/download-clients";
import { IndexersPage } from "./pages/admin/indexers";
import { LibraryPathsPage } from "./pages/admin/library-paths";
import { MediaServersPage } from "./pages/admin/media-servers";
import { RemoteAccessPage } from "./pages/admin/remote-access";
import { TranscodesPage } from "./pages/admin/transcodes";
import { DevicesPage } from "./pages/admin/devices";

function NotFound() {
  return (
    <div className="flex items-center justify-center min-h-[50vh]">
      <div className="text-center">
        <h1 className="text-4xl font-bold">404</h1>
        <p className="text-base-content/60 mt-2">Page not found</p>
      </div>
    </div>
  );
}

export const router = createBrowserRouter([
  {
    path: "/login",
    element: <LoginPage />,
  },
  {
    element: (
      <RequireAuth>
        <AppShell />
      </RequireAuth>
    ),
    children: [
      { index: true, element: <DashboardPage /> },
      { path: "dashboard", element: <DashboardPage /> },
      { path: "discover", element: <DiscoverPage /> },
      { path: "movies", element: <MoviesPage /> },
      { path: "tv-shows", element: <TvShowsPage /> },
      { path: "calendar", element: <CalendarPage /> },
      { path: "downloads", element: <DownloadsPage /> },
      { path: "add-media", element: <AddMediaPage /> },
      { path: "import-media", element: <ImportMediaPage /> },
      { path: "search", element: <SearchPage /> },
      { path: "collections", element: <CollectionsPage /> },
      { path: "collections/:id", element: <CollectionsPage /> },
      { path: "media/:id", element: <MediaDetailPage /> },
      { path: "play/:type/:id", element: <PlaybackPage /> },
      { path: "profile", element: <ProfilePage /> },
      { path: "my-requests", element: <MyRequestsPage /> },
      { path: "request-media", element: <RequestMediaPage /> },

      // Admin: standalone pages
      { path: "admin/activity", element: <RequireAdmin><ActivityPage /></RequireAdmin> },
      { path: "admin/users", element: <RequireAdmin><UsersPage /></RequireAdmin> },
      { path: "admin/import-lists", element: <RequireAdmin><ImportListsPage /></RequireAdmin> },
      { path: "admin/jobs", element: <RequireAdmin><JobsPage /></RequireAdmin> },
      { path: "admin/release-blacklist", element: <RequireAdmin><ReleaseBlacklistPage /></RequireAdmin> },
      { path: "admin/requests", element: <RequireAdmin><RequestsPage /></RequireAdmin> },
      { path: "admin/transcodes", element: <RequireAdmin><TranscodesPage /></RequireAdmin> },
      { path: "admin/devices", element: <RequireAdmin><DevicesPage /></RequireAdmin> },

      // Admin: config pages under AdminConfigShell layout
      {
        path: "admin/config",
        element: <RequireAdmin><AdminConfigShell /></RequireAdmin>,
        children: [
          { path: "system", element: <SystemPage /> },
          { path: "settings", element: <SettingsPage /> },
          { path: "quality-profiles", element: <QualityProfilesPage /> },
          { path: "download-clients", element: <DownloadClientsPage /> },
          { path: "indexers", element: <IndexersPage /> },
          { path: "library-paths", element: <LibraryPathsPage /> },
          { path: "media-servers", element: <MediaServersPage /> },
          { path: "remote-access", element: <RemoteAccessPage /> },
        ],
      },
    ],
  },
  {
    path: "*",
    element: <NotFound />,
  },
]);
