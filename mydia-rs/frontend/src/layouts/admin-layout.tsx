import { Outlet, Link, useLocation } from "react-router-dom";
import { useViewer } from "../lib/auth";
import { useTheme } from "../lib/theme";
import { ToastContainer } from "../components/feedback";

export function AdminLayout() {
  const { viewer } = useViewer();
  const { theme, toggle } = useTheme();
  const location = useLocation();

  const isActive = (path: string) => {
    return location.pathname.startsWith(path) ? "menu-active" : "";
  };

  return (
    <div className="flex min-h-screen">
      {/* Sidebar */}
      <aside className="w-64 bg-base-100 border-r border-base-300 flex flex-col shrink-0">
        <div className="p-4 border-b border-base-300">
          <Link to="/" className="text-xl font-bold text-primary">
            Mydia
          </Link>
          <p className="text-xs text-base-content/50 mt-1">Admin Console</p>
        </div>

        <nav className="flex-1 p-3 overflow-y-auto">
          <ul className="menu gap-0.5">
            <li>
              <Link to="/dashboard" className={isActive("/dashboard")}>
                Dashboard
              </Link>
            </li>
            <li>
              <Link to="/calendar" className={isActive("/calendar")}>
                Calendar
              </Link>
            </li>
            <li>
              <Link to="/discover" className={isActive("/discover")}>
                Discover
              </Link>
            </li>
            <li>
              <Link to="/search" className={isActive("/search")}>
                Search
              </Link>
            </li>

            <li className="menu-title mt-4">
              <span>Library</span>
            </li>
            <li>
              <Link
                to="/admin/library-paths"
                className={isActive("/admin/library-paths")}
              >
                Library Paths
              </Link>
            </li>
            <li>
              <Link
                to="/admin/indexers"
                className={isActive("/admin/indexers")}
              >
                Indexers
              </Link>
            </li>
            <li>
              <Link
                to="/admin/download-clients"
                className={isActive("/admin/download-clients")}
              >
                Download Clients
              </Link>
            </li>
            <li>
              <Link
                to="/admin/import-lists"
                className={isActive("/admin/import-lists")}
              >
                Import Lists
              </Link>
            </li>
            <li>
              <Link
                to="/admin/media-servers"
                className={isActive("/admin/media-servers")}
              >
                Media Servers
              </Link>
            </li>
            <li>
              <Link
                to="/admin/quality-profiles"
                className={isActive("/admin/quality-profiles")}
              >
                Quality Profiles
              </Link>
            </li>
            <li>
              <Link
                to="/admin/release-blacklist"
                className={isActive("/admin/release-blacklist")}
              >
                Release Blacklist
              </Link>
            </li>

            <li className="menu-title mt-4">
              <span>Operations</span>
            </li>
            <li>
              <Link to="/admin/jobs" className={isActive("/admin/jobs")}>
                Jobs
              </Link>
            </li>
            <li>
              <Link
                to="/admin/transcodes"
                className={isActive("/admin/transcodes")}
              >
                Transcodes
              </Link>
            </li>
            <li>
              <Link
                to="/admin/downloads"
                className={isActive("/admin/downloads")}
              >
                Downloads
              </Link>
            </li>
            <li>
              <Link
                to="/admin/devices"
                className={isActive("/admin/devices")}
              >
                Devices
              </Link>
            </li>
            <li>
              <Link
                to="/admin/remote-access"
                className={isActive("/admin/remote-access")}
              >
                Remote Access
              </Link>
            </li>
            <li>
              <Link
                to="/admin/requests"
                className={isActive("/admin/requests")}
              >
                Requests
              </Link>
            </li>
            <li>
              <Link
                to="/admin/activity"
                className={isActive("/admin/activity")}
              >
                Activity
              </Link>
            </li>

            <li className="menu-title mt-4">
              <span>System</span>
            </li>
            <li>
              <Link
                to="/admin/settings"
                className={isActive("/admin/settings")}
              >
                Settings
              </Link>
            </li>
            <li>
              <Link
                to="/admin/system"
                className={isActive("/admin/system")}
              >
                System
              </Link>
            </li>
            <li>
              <Link to="/admin/users" className={isActive("/admin/users")}>
                Users
              </Link>
            </li>
          </ul>
        </nav>

        <div className="p-3 border-t border-base-300 flex items-center justify-between">
          <div className="text-sm text-base-content/70 truncate">
            {viewer?.username}
          </div>
          <div className="flex items-center gap-1">
            <button
              className="btn btn-ghost btn-xs"
              onClick={toggle}
              title={`Switch to ${theme === "mydia-dark" ? "light" : "dark"} theme`}
            >
              {theme === "mydia-dark" ? "☀" : "☾"}
            </button>
            <button
              className="btn btn-ghost btn-xs"
              onClick={() => {
                fetch("/auth/logout", { method: "POST" }).then(() => {
                  window.location.assign("/login");
                });
              }}
              title="Log out"
            >
              Log out
            </button>
          </div>
        </div>
      </aside>

      {/* Main content */}
      <main className="flex-1 p-6 overflow-y-auto">
        <Outlet />
      </main>

      <ToastContainer />
    </div>
  );
}
