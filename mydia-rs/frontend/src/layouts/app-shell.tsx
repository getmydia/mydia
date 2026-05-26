import { Outlet, Link, useLocation } from "react-router-dom";
import { useViewer } from "../lib/auth";
import { useTheme } from "../lib/theme";
import { ToastContainer } from "../components/feedback";

type NavItem = {
  to: string;
  icon: string;
  label: string;
  badge?: number | null;
};

function MenuIcon({ name }: { name: string }) {
  const icons: Record<string, string> = {
    home: "M2.25 12l8.954-8.955a1.126 1.126 0 011.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75M8.25 21h8.25",
    sparkles: "M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09zM18.259 8.715L18 9.75l-.259-1.035a3.375 3.375 0 00-2.455-2.456L14.25 6l1.036-.259a3.375 3.375 0 002.455-2.456L18 2.25l.259 1.035a3.375 3.375 0 002.455 2.456L21.75 6l-1.036.259a3.375 3.375 0 00-2.455 2.456zM16.894 20.567L16.5 21.75l-.394-1.183a2.25 2.25 0 00-1.423-1.423L13.5 18.75l1.183-.394a2.25 2.25 0 001.423-1.423l.394-1.183.394 1.183a2.25 2.25 0 001.423 1.423l1.183.394-1.183.394a2.25 2.25 0 00-1.423 1.423z",
    film: "M3.375 19.5h17.25m-17.25 0a1.125 1.125 0 01-1.125-1.125M3.375 19.5h7.5c.621 0 1.125-.504 1.125-1.125m-9.75 0V5.625m0 12.75v-1.5c0-.621.504-1.125 1.125-1.125m18.375 2.625V5.625m0 12.75c0 .621-.504 1.125-1.125 1.125m1.125-1.125v-1.5c0-.621-.504-1.125-1.125-1.125m0 3.75h-7.5A1.125 1.125 0 0112 18.375m9.75-12.75c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125m19.5 0v1.5c0 .621-.504 1.125-1.125 1.125M2.25 5.625v1.5c0 .621.504 1.125 1.125 1.125m0 0h17.25m-17.25 0h7.5c.621 0 1.125.504 1.125 1.125M3.375 8.25c-.621 0-1.125.504-1.125 1.125v1.5c0 .621.504 1.125 1.125 1.125m17.25-3.75h-7.5c-.621 0-1.125.504-1.125 1.125m8.625-1.125c.621 0 1.125.504 1.125 1.125v1.5c0 .621-.504 1.125-1.125 1.125m-17.25 0h7.5m-7.5 0c-.621 0-1.125.504-1.125 1.125v1.5c0 .621.504 1.125 1.125 1.125M12 10.875v-1.5m0 1.5c0 .621-.504 1.125-1.125 1.125M12 10.875c0 .621.504 1.125 1.125 1.125m-2.25 0c.621 0 1.125.504 1.125 1.125m4.125-1.125c.621 0 1.125.504 1.125 1.125m-7.5 0A1.125 1.125 0 0110.875 18M15.75 12a1.125 1.125 0 011.125 1.125M15.75 12a1.125 1.125 0 00-1.125 1.125M10.875 18h3.375",
    tv: "M6 20.25h12m-7.5-3v3m3-3v3m-10.125-3h17.25c.621 0 1.125-.504 1.125-1.125V4.875c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125v11.25c0 .621.504 1.125 1.125 1.125z",
    calendar: "M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 012.25-2.25h13.5A2.25 2.25 0 0121 7.5v11.25m-18 0A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75m-18 0v-7.5A2.25 2.25 0 015.25 9h13.5A2.25 2.25 0 0121 11.25v7.5",
    clock: "M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z",
    "arrow-down-tray": "M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5",
    "plus-circle": "M12 9v6m3-3H9m12 0a9 9 0 11-18 0 9 9 0 0118 0z",
    "arrow-down-on-square-stack": "M7.5 7.5h-.75A2.25 2.25 0 004.5 9.75v7.5a2.25 2.25 0 002.25 2.25h7.5a2.25 2.25 0 002.25-2.25v-7.5a2.25 2.25 0 00-2.25-2.25h-.75m-6 3.75l3 3m0 0l3-3m-3 3V1.5m6 9h.75a2.25 2.25 0 012.25 2.25v7.5a2.25 2.25 0 01-2.25 2.25h-7.5a2.25 2.25 0 01-2.25-2.25v-.75",
    "magnifying-glass": "M21 21l-5.197-5.197m0 0A7.5 7.5 0 105.196 5.196a7.5 7.5 0 0010.607 10.607z",
    folder: "M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z",
    users: "M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 018.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0111.964-3.07M12 6.375a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zm8.25 2.25a2.625 2.625 0 11-5.25 0 2.625 2.625 0 015.25 0z",
    "cog-6-tooth": "M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.324.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 011.37.49l1.296 2.247a1.125 1.125 0 01-.26 1.431l-1.003.827c-.293.24-.438.613-.431.992a6.759 6.759 0 010 .255c-.007.378.138.75.43.99l1.005.828c.424.35.534.954.26 1.43l-1.298 2.247a1.125 1.125 0 01-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.57 6.57 0 01-.22.128c-.331.183-.581.495-.644.869l-.213 1.28c-.09.543-.56.941-1.11.941h-2.594c-.55 0-1.02-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 01-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 01-1.369-.49l-1.297-2.247a1.125 1.125 0 01.26-1.431l1.004-.827c.292-.24.437-.613.43-.992a6.932 6.932 0 010-.255c.007-.378-.138-.75-.43-.99l-1.004-.828a1.125 1.125 0 01-.26-1.43l1.297-2.247a1.125 1.125 0 011.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.087.22-.128.332-.183.582-.495.644-.869l.214-1.281z",
    "queue-list": "M3.75 12h16.5m-16.5 3.75h16.5M3.75 19.5h16.5M5.625 4.5h12.75a1.875 1.875 0 010 3.75H5.625a1.875 1.875 0 010-3.75z",
    "no-symbol": "M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636",
    "inbox-stack": "M7.5 7.5h-.75A2.25 2.25 0 004.5 9.75v7.5a2.25 2.25 0 002.25 2.25h7.5a2.25 2.25 0 002.25-2.25v-7.5a2.25 2.25 0 00-2.25-2.25h-.75m0-3l-3-3m0 0l-3 3m3-3v11.25m6-2.25h.75a2.25 2.25 0 012.25 2.25v7.5a2.25 2.25 0 01-2.25 2.25h-7.5a2.25 2.25 0 01-2.25-2.25v-.75",
    user: "M15.75 6a3.75 3.75 0 11-7.5 0 3.75 3.75 0 017.5 0zM4.501 20.118a7.5 7.5 0 0114.998 0A17.933 17.933 0 0112 21.75c-2.676 0-5.216-.584-7.499-1.632z",
    "arrow-right-on-rectangle": "M15.75 9V5.25A2.25 2.25 0 0013.5 3h-6a2.25 2.25 0 00-2.25 2.25v13.5A2.25 2.25 0 007.5 21h6a2.25 2.25 0 002.25-2.25V15m3 0l3-3m0 0l-3-3m3 3H9",
    sun: "M12 3v2.25m6.364.386l-1.591 1.591M21 12h-2.25m-.386 6.364l-1.591-1.591M12 18.75V21m-4.773-4.227l-1.591 1.591M5.25 12H3m4.227-4.773L5.636 5.636M15.75 12a3.75 3.75 0 11-7.5 0 3.75 3.75 0 017.5 0z",
    moon: "M21.752 15.002A9.718 9.718 0 0118 15.75c-5.385 0-9.75-4.365-9.75-9.75 0-1.33.266-2.597.748-3.752A9.753 9.753 0 003 11.25C3 16.635 7.365 21 12.75 21a9.753 9.753 0 009.002-5.998z",
    "computer-desktop": "M9 17.25v1.007a3 3 0 01-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0115 18.257V17.25m6-12V15a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 15V5.25m18 0A2.25 2.25 0 0018.75 3H5.25A2.25 2.25 0 003 5.25m18 0V12a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 12V5.25",
    bars3: "M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5",
  };
  const path = icons[name];
  if (!path) return null;
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      strokeWidth={1.5}
      stroke="currentColor"
      className="w-5 h-5"
    >
      <path strokeLinecap="round" strokeLinejoin="round" d={path} />
    </svg>
  );
}

function SidebarNavItem({ item }: { item: NavItem }) {
  const location = useLocation();
  const isActive = location.pathname === item.to || location.pathname.startsWith(item.to + "/");

  return (
    <li>
      <Link to={item.to} className={isActive ? "active" : ""}>
        <MenuIcon name={item.icon} />
        {item.label}
        {item.badge != null && item.badge > 0 && (
          <span className="badge badge-sm">{item.badge}</span>
        )}
      </Link>
    </li>
  );
}

function SectionTitle({ label }: { label: string }) {
  return (
    <li className="menu-title mt-4">
      <span>{label}</span>
    </li>
  );
}

function MobileDockLink({ to, icon, label }: { to: string; icon: string; label: string }) {
  return (
    <Link
      to={to}
      className="flex flex-col items-center justify-center min-w-[52px] py-1.5 rounded-xl opacity-60 hover:opacity-100 transition-opacity"
    >
      <MenuIcon name={icon} />
      <span className="text-[10px] mt-0.5">{label}</span>
    </Link>
  );
}

export function AppShell() {
  const { viewer, isAdmin } = useViewer();
  const { theme, toggle } = useTheme();
  const isGuest = viewer?.role === "guest";

  return (
    <div className="drawer lg:drawer-open">
      <input id="main-drawer" type="checkbox" className="drawer-toggle" />

      {/* Content column */}
      <div className="drawer-content flex flex-col">
        {/* Mobile navbar */}
        <header className="lg:hidden navbar bg-base-300 border-b border-base-content/10">
          <div className="flex-none">
            <label
              htmlFor="main-drawer"
              className="btn btn-square btn-ghost"
              aria-label="Open menu"
            >
              <MenuIcon name="bars3" />
            </label>
          </div>
          <div className="flex-1 px-2">
            <Link to="/" className="text-xl font-bold text-primary">Mydia</Link>
          </div>
          <div className="flex-none">
            <button className="btn btn-ghost btn-square" onClick={toggle}>
              {theme === "mydia-dark" ? <MenuIcon name="sun" /> : <MenuIcon name="moon" />}
            </button>
          </div>
        </header>

        <main className="flex-1 overflow-y-auto p-3 sm:p-4 md:p-6 lg:p-8 pb-20 lg:pb-8 min-h-screen bg-base-200">
          <Outlet />
        </main>

        {/* Mobile dock */}
        <nav className="lg:hidden fixed z-50 left-3 right-3 bottom-3 flex items-center justify-around rounded-2xl px-2 py-2 bg-base-100/60 backdrop-blur-3xl backdrop-saturate-150 border border-white/20 shadow-[0_8px_32px_rgba(0,0,0,0.12),inset_0_1px_0_rgba(255,255,255,0.2)]">
          <MobileDockLink to="/" icon="home" label="Home" />
          <MobileDockLink to="/discover" icon="sparkles" label="Discover" />
          {isGuest ? (
            <>
              <MobileDockLink to="/request-media" icon="film" label="Request" />
              <MobileDockLink to="/my-requests" icon="queue-list" label="Requests" />
            </>
          ) : (
            <>
              <MobileDockLink to="/movies" icon="film" label="Movies" />
              <MobileDockLink to="/tv-shows" icon="tv" label="TV" />
              <MobileDockLink to="/profile" icon="user" label="Profile" />
            </>
          )}
        </nav>
      </div>

      {/* Sidebar */}
      <div className="drawer-side z-40">
        <label htmlFor="main-drawer" aria-label="close sidebar" className="drawer-overlay" />
        <aside className="flex flex-col w-64 min-h-full bg-base-300 text-base-content border-r border-base-content/10">
          {/* Branding */}
          <div className="p-4 border-b border-base-content/10">
            <Link to="/" className="flex items-center gap-2 hover:text-primary transition-colors">
              <div className="w-8 h-8 rounded-md bg-primary text-primary-content flex items-center justify-center font-bold">
                M
              </div>
              <h1 className="text-2xl font-bold">Mydia</h1>
            </Link>
          </div>

          {/* Navigation */}
          <nav className="flex-1 overflow-y-auto">
            <ul className="menu w-full space-y-1 px-2 py-4">
              <SidebarNavItem item={{ to: "/", icon: "home", label: "Dashboard" }} />
              <SidebarNavItem item={{ to: "/discover", icon: "sparkles", label: "Discover" }} />
              <SidebarNavItem item={{ to: "/movies", icon: "film", label: "Movies" }} />
              <SidebarNavItem item={{ to: "/tv-shows", icon: "tv", label: "TV Shows" }} />

              {!isGuest && (
                <>
                  <SectionTitle label="Library" />
                  <SidebarNavItem item={{ to: "/calendar", icon: "calendar", label: "Calendar" }} />

                  <SectionTitle label="Management" />
                  <SidebarNavItem item={{ to: "/downloads", icon: "arrow-down-tray", label: "Downloads" }} />
                  <SidebarNavItem item={{ to: "/add-media", icon: "plus-circle", label: "Add media" }} />
                  <SidebarNavItem item={{ to: "/import-media", icon: "arrow-down-on-square-stack", label: "Import library" }} />
                  <SidebarNavItem item={{ to: "/search", icon: "magnifying-glass", label: "Search" }} />
                  <SidebarNavItem item={{ to: "/collections", icon: "folder", label: "Collections" }} />
                </>
              )}

              {isAdmin && (
                <>
                  <SectionTitle label="Administration" />
                  <SidebarNavItem item={{ to: "/admin/users", icon: "users", label: "Users" }} />
                  <SidebarNavItem item={{ to: "/admin/config/system", icon: "cog-6-tooth", label: "Configuration" }} />
                  <SidebarNavItem item={{ to: "/admin/import-lists", icon: "arrow-down-on-square-stack", label: "Import Lists" }} />
                  <SidebarNavItem item={{ to: "/admin/jobs", icon: "queue-list", label: "Background Jobs" }} />
                  <SidebarNavItem item={{ to: "/admin/activity", icon: "clock", label: "Activity" }} />
                  <SidebarNavItem item={{ to: "/admin/release-blacklist", icon: "no-symbol", label: "Release Blacklist" }} />
                  <SidebarNavItem item={{ to: "/admin/requests", icon: "inbox-stack", label: "Requests" }} />
                </>
              )}

              {isGuest && (
                <>
                  <SectionTitle label="Requests" />
                  <SidebarNavItem item={{ to: "/request-media", icon: "film", label: "Request Media" }} />
                  <SidebarNavItem item={{ to: "/my-requests", icon: "queue-list", label: "My Requests" }} />
                </>
              )}
            </ul>
          </nav>

          {/* User menu */}
          <div className="space-y-3 p-4 border-t border-base-300">
            <div className="dropdown dropdown-top dropdown-end w-full">
              <label tabIndex={0} className="btn btn-ghost w-full justify-start">
                <div className="avatar placeholder">
                  <div className="bg-neutral text-neutral-content rounded-full w-8">
                    <span className="text-xs">
                      {(viewer?.username ?? "?").slice(0, 2).toUpperCase()}
                    </span>
                  </div>
                </div>
                <div className="flex-1 text-left">
                  <div className="text-sm font-medium">{viewer?.username ?? "Unknown"}</div>
                  <div className="text-xs opacity-60 capitalize">{viewer?.role ?? "user"}</div>
                </div>
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor" className="w-4 h-4">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 15.75l7.5-7.5 7.5 7.5" />
                </svg>
              </label>
              <ul tabIndex={0} className="dropdown-content menu p-2 shadow-lg bg-base-200 rounded-box w-52 mb-2">
                <li>
                  <Link to="/profile">
                    <MenuIcon name="cog-6-tooth" />
                    Settings
                  </Link>
                </li>
                <li className="mt-2 border-t border-base-300 pt-2">
                  <button
                    type="button"
                    className="text-error"
                    onClick={() => {
                      fetch("/auth/logout", {
                        method: "POST",
                        credentials: "include",
                        headers: { "X-Mydia-Client": "web" },
                      }).then(() => {
                        window.location.assign("/login");
                      });
                    }}
                  >
                    <MenuIcon name="arrow-right-on-rectangle" />
                    Logout
                  </button>
                </li>
              </ul>
            </div>

            <div className="hidden lg:flex justify-center">
              <button
                className="btn btn-ghost btn-sm gap-2"
                onClick={toggle}
                title={`Switch to ${theme === "mydia-dark" ? "light" : "dark"} theme`}
              >
                {theme === "mydia-dark" ? <MenuIcon name="sun" /> : <MenuIcon name="moon" />}
                {theme === "mydia-dark" ? "Light" : "Dark"} mode
              </button>
            </div>
          </div>
        </aside>
      </div>

      <ToastContainer />
    </div>
  );
}
