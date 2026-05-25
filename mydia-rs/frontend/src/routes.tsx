import { createBrowserRouter } from "react-router-dom";
import { RequireAuth, RequireAdmin } from "./lib/auth";
import { AdminLayout } from "./layouts/admin-layout";
import { UserLayout } from "./layouts/user-layout";
import { LoginPage } from "./pages/login";
import { DashboardPage } from "./pages/dashboard";
import { CalendarPage } from "./pages/calendar";
import { DiscoverPage } from "./pages/discover";
import { SearchPage } from "./pages/search";
import { AddMediaPage } from "./pages/add-media";
import { ImportMediaPage } from "./pages/import-media";
import { MediaDetailPage } from "./pages/media-detail";
import { MyRequestsPage } from "./pages/my-requests";
import { RequestMediaPage } from "./pages/request-media";
import { ProfilePage } from "./pages/profile";
import { LibraryPathsPage } from "./pages/admin/library-paths";
import { IndexersPage } from "./pages/admin/indexers";
import { DownloadClientsPage } from "./pages/admin/download-clients";
import { ImportListsPage } from "./pages/admin/import-lists";
import { MediaServersPage } from "./pages/admin/media-servers";
import { QualityProfilesPage } from "./pages/admin/quality-profiles";
import { ReleaseBlacklistPage } from "./pages/admin/release-blacklist";

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
        <UserLayout />
      </RequireAuth>
    ),
    children: [
      {
        index: true,
        element: <DashboardPage />,
      },
      {
        path: "dashboard",
        element: <DashboardPage />,
      },
      {
        path: "calendar",
        element: <CalendarPage />,
      },
      {
        path: "discover",
        element: <DiscoverPage />,
      },
      {
        path: "search",
        element: <SearchPage />,
      },
      {
        path: "add-media",
        element: <AddMediaPage />,
      },
      {
        path: "import-media",
        element: <ImportMediaPage />,
      },
      {
        path: "media/:id",
        element: <MediaDetailPage />,
      },
      {
        path: "my-requests",
        element: <MyRequestsPage />,
      },
      {
        path: "request-media",
        element: <RequestMediaPage />,
      },
      {
        path: "profile",
        element: <ProfilePage />,
      },
    ],
  },
  {
    element: (
      <RequireAdmin>
        <AdminLayout />
      </RequireAdmin>
    ),
    children: [
      {
        path: "admin/library-paths",
        element: <LibraryPathsPage />,
      },
      {
        path: "admin/indexers",
        element: <IndexersPage />,
      },
      {
        path: "admin/download-clients",
        element: <DownloadClientsPage />,
      },
      {
        path: "admin/import-lists",
        element: <ImportListsPage />,
      },
      {
        path: "admin/media-servers",
        element: <MediaServersPage />,
      },
      {
        path: "admin/quality-profiles",
        element: <QualityProfilesPage />,
      },
      {
        path: "admin/release-blacklist",
        element: <ReleaseBlacklistPage />,
      },
      {
        path: "admin/jobs",
        element: <PagePlaceholder title="Jobs" />,
      },
      {
        path: "admin/transcodes",
        element: <PagePlaceholder title="Transcodes" />,
      },
      {
        path: "admin/downloads",
        element: <PagePlaceholder title="Downloads" />,
      },
      {
        path: "admin/devices",
        element: <PagePlaceholder title="Devices" />,
      },
      {
        path: "admin/remote-access",
        element: <PagePlaceholder title="Remote Access" />,
      },
      {
        path: "admin/requests",
        element: <PagePlaceholder title="Requests" />,
      },
      {
        path: "admin/activity",
        element: <PagePlaceholder title="Activity" />,
      },
      {
        path: "admin/settings",
        element: <PagePlaceholder title="Settings" />,
      },
      {
        path: "admin/system",
        element: <PagePlaceholder title="System" />,
      },
      {
        path: "admin/users",
        element: <PagePlaceholder title="Users" />,
      },
    ],
  },
  {
    path: "*",
    element: <NotFound />,
  },
]);

function PagePlaceholder({ title }: { title: string }) {
  return (
    <div>
      <h1 className="text-2xl font-bold mb-6">{title}</h1>
      <div className="alert">
        <span className="text-base-content/60">
          This page will be migrated from the Dioxus stack soon.
        </span>
      </div>
    </div>
  );
}


