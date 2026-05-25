import { createBrowserRouter } from "react-router-dom";
import { RequireAuth, RequireAdmin } from "./lib/auth";
import { AdminLayout } from "./layouts/admin-layout";
import { UserLayout } from "./layouts/user-layout";
import { LoginPage } from "./pages/login";

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
        element: <DashboardPlaceholder />,
      },
      {
        path: "dashboard",
        element: <DashboardPlaceholder />,
      },
      {
        path: "calendar",
        element: <PagePlaceholder title="Calendar" />,
      },
      {
        path: "discover",
        element: <PagePlaceholder title="Discover" />,
      },
      {
        path: "search",
        element: <PagePlaceholder title="Search" />,
      },
      {
        path: "add-media",
        element: <PagePlaceholder title="Add Media" />,
      },
      {
        path: "import-media",
        element: <PagePlaceholder title="Import Media" />,
      },
      {
        path: "media/:id",
        element: <PagePlaceholder title="Media Detail" />,
      },
      {
        path: "my-requests",
        element: <PagePlaceholder title="My Requests" />,
      },
      {
        path: "request-media",
        element: <PagePlaceholder title="Request Media" />,
      },
      {
        path: "profile",
        element: <PagePlaceholder title="Profile" />,
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
        element: <PagePlaceholder title="Library Paths" />,
      },
      {
        path: "admin/indexers",
        element: <PagePlaceholder title="Indexers" />,
      },
      {
        path: "admin/download-clients",
        element: <PagePlaceholder title="Download Clients" />,
      },
      {
        path: "admin/import-lists",
        element: <PagePlaceholder title="Import Lists" />,
      },
      {
        path: "admin/media-servers",
        element: <PagePlaceholder title="Media Servers" />,
      },
      {
        path: "admin/quality-profiles",
        element: <PagePlaceholder title="Quality Profiles" />,
      },
      {
        path: "admin/release-blacklist",
        element: <PagePlaceholder title="Release Blacklist" />,
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

function DashboardPlaceholder() {
  return (
    <div>
      <h1 className="text-2xl font-bold mb-6">Dashboard</h1>
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        {["TV Shows", "Movies", "Episodes", "Downloads"].map((stat) => (
          <div key={stat} className="card bg-base-100 shadow">
            <div className="card-body p-5">
              <h3 className="text-sm text-base-content/60">{stat}</h3>
              <p className="text-2xl font-bold">--</p>
            </div>
          </div>
        ))}
      </div>
      <div className="card bg-base-100 shadow">
        <div className="card-body">
          <h2 className="card-title">Recent Activity</h2>
          <p className="text-base-content/60">Activity feed coming soon.</p>
        </div>
      </div>
    </div>
  );
}

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
