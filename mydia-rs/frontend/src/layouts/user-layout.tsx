import { Outlet, Link, useLocation } from "react-router-dom";
import { useViewer } from "../lib/auth";
import { useTheme } from "../lib/theme";
import { ToastContainer } from "../components/feedback";

export function UserLayout() {
  const { viewer } = useViewer();
  const { theme, toggle } = useTheme();
  const location = useLocation();

  const isActive = (path: string) => {
    return location.pathname === path ? "btn-active" : "";
  };

  return (
    <div className="min-h-screen flex flex-col">
      <header className="navbar bg-base-100 border-b border-base-300 px-6">
        <div className="flex-1">
          <Link to="/" className="text-xl font-bold text-primary">
            Mydia
          </Link>
        </div>
        <div className="flex-none gap-2">
          <Link
            to="/dashboard"
            className={["btn btn-ghost btn-sm", isActive("/dashboard")].join(" ")}
          >
            Dashboard
          </Link>
          <Link
            to="/calendar"
            className={["btn btn-ghost btn-sm", isActive("/calendar")].join(" ")}
          >
            Calendar
          </Link>
          <Link
            to="/discover"
            className={["btn btn-ghost btn-sm", isActive("/discover")].join(" ")}
          >
            Discover
          </Link>
          <div className="dropdown dropdown-end">
            <label tabIndex={0} className="btn btn-ghost btn-sm">
              {viewer?.username ?? "Account"}
            </label>
            <ul
              tabIndex={0}
              className="dropdown-content menu p-2 shadow bg-base-100 rounded-box w-48 mt-2"
            >
              <li>
                <Link to="/profile">Profile</Link>
              </li>
              <li>
                <Link to="/my-requests">My Requests</Link>
              </li>
              <li>
                <button
                  onClick={toggle}
                  className="flex items-center gap-2"
                >
                  {theme === "mydia-dark" ? "Light mode" : "Dark mode"}
                </button>
              </li>
              <li>
                <button
                  onClick={() => {
                    fetch("/auth/logout", { method: "POST" }).then(() => {
                      window.location.assign("/login");
                    });
                  }}
                >
                  Log out
                </button>
              </li>
            </ul>
          </div>
        </div>
      </header>

      <main className="flex-1 p-6">
        <Outlet />
      </main>

      <ToastContainer />
    </div>
  );
}
