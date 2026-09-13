defmodule MydiaWeb.AdminNav do
  @moduledoc """
  Every admin page: its hub, label, one-line description, icon and path.

  This one list drives the sidebar's Admin section, the header each admin page
  renders, and which legacy `/admin/config/*` URLs redirect. A new admin page
  needs an entry here; `test/mydia_web/admin_nav_test.exs` fails for a live route
  under `/admin` that has none.

  Hubs: **Configuration** holds acquisition levers, **Administration** holds work
  an operator has to act on, **System** holds the server itself.
  """

  use MydiaWeb, :verified_routes

  alias MydiaWeb.AdminNav.Page

  @hubs [
    %{key: :configuration, label: "Configuration", icon: "hero-adjustments-horizontal"},
    %{key: :administration, label: "Administration", icon: "hero-clipboard-document-check"},
    %{key: :system, label: "System", icon: "hero-server"}
  ]

  # A literal, so `MydiaWeb.AdminComponents.admin_page/1` can check `page={...}`
  # at compile time. pages/0 cannot supply it then: `~p` resolves through the
  # endpoint at runtime. The registry test pins this list to pages/0's order.
  @keys [
    :quality,
    :custom_formats,
    :clients,
    :indexers,
    :library_paths,
    :path_mappings,
    :subtitle_providers,
    :import_lists,
    :media_servers,
    :requests,
    :jobs,
    :release_blacklist,
    :duplicates,
    :trash,
    :status,
    :dashboard,
    :settings,
    :users,
    :api_keys,
    :remote_access,
    :plugins
  ]

  @doc "The hubs, in sidebar order."
  @spec hubs() :: [%{key: Page.hub(), label: String.t(), icon: String.t()}]
  def hubs, do: @hubs

  @doc "The label of `hub`."
  @spec hub_label(Page.hub()) :: String.t()
  def hub_label(hub), do: @hubs |> Enum.find(&(&1.key == hub)) |> Map.fetch!(:label)

  @doc """
  Where the sidebar link for `hub` goes: the hub's first page whose feature gate
  is on. Every hub has an ungated page, so there always is one.
  """
  @spec hub_landing_path(Page.hub()) :: String.t()
  def hub_landing_path(hub), do: hub |> visible_pages() |> hd() |> Map.fetch!(:path)

  @doc "Every page key, in sidebar order."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc "Every admin page, grouped by hub, in sidebar order."
  @spec pages() :: [Page.t()]
  def pages do
    [
      %Page{
        key: :quality,
        hub: :configuration,
        label: "Quality",
        description: "Profiles that decide which releases get grabbed and upgraded",
        icon: "hero-sparkles",
        path: ~p"/admin/quality"
      },
      %Page{
        key: :custom_formats,
        hub: :configuration,
        label: "Custom Formats",
        description: "Rules that score releases",
        icon: "hero-language",
        path: ~p"/admin/custom-formats"
      },
      %Page{
        key: :clients,
        hub: :configuration,
        label: "Clients",
        description: "Torrent, Usenet and debrid download clients",
        icon: "hero-arrow-down-tray",
        path: ~p"/admin/clients"
      },
      %Page{
        key: :indexers,
        hub: :configuration,
        label: "Indexers",
        description: "Where searches look for releases",
        icon: "hero-magnifying-glass",
        path: ~p"/admin/indexers"
      },
      %Page{
        key: :library_paths,
        hub: :configuration,
        label: "Library",
        description: "Library folders for movies and TV",
        icon: "hero-folder",
        path: ~p"/admin/library-paths"
      },
      %Page{
        key: :path_mappings,
        hub: :configuration,
        label: "Path Mappings",
        description: "Translate download client paths to paths this server sees",
        icon: "hero-arrows-right-left",
        path: ~p"/admin/path-mappings"
      },
      %Page{
        key: :subtitle_providers,
        hub: :configuration,
        label: "Subtitle Providers",
        description: "Where subtitles are searched and downloaded",
        icon: "hero-chat-bubble-bottom-center-text",
        path: ~p"/admin/subtitle-providers"
      },
      %Page{
        key: :import_lists,
        hub: :configuration,
        label: "Import Lists",
        description: "Lists that add media automatically",
        icon: "hero-arrow-down-on-square-stack",
        path: ~p"/admin/import-lists",
        requires: :import_lists
      },
      %Page{
        key: :media_servers,
        hub: :configuration,
        label: "Media Servers",
        description: "Plex and Jellyfin refresh and watched-status sync",
        icon: "hero-server-stack",
        path: ~p"/admin/media-servers"
      },
      %Page{
        key: :requests,
        hub: :administration,
        label: "Requests",
        description: "Approve or reject media requests from guests",
        icon: "hero-inbox-stack",
        path: ~p"/admin/requests"
      },
      %Page{
        key: :jobs,
        hub: :administration,
        label: "Background Jobs",
        description: "Scheduled jobs and execution history",
        icon: "hero-queue-list",
        path: ~p"/admin/jobs"
      },
      %Page{
        key: :release_blacklist,
        hub: :administration,
        label: "Release Blacklist",
        description: "Releases blocked from future searches",
        icon: "hero-no-symbol",
        path: ~p"/admin/release-blacklist"
      },
      %Page{
        key: :duplicates,
        hub: :administration,
        label: "Duplicates",
        description: "Items with more than one file to review",
        icon: "hero-document-duplicate",
        path: ~p"/admin/duplicates"
      },
      %Page{
        key: :trash,
        hub: :administration,
        label: "Trash",
        description: "Deleted files waiting to be purged",
        icon: "hero-trash",
        path: ~p"/admin/trash"
      },
      %Page{
        key: :status,
        hub: :system,
        label: "Status",
        description: "Server, database and service health",
        icon: "hero-server",
        path: ~p"/admin/status"
      },
      %Page{
        key: :dashboard,
        hub: :system,
        label: "Dashboard",
        description: "Playback activity and active sessions",
        icon: "hero-chart-bar",
        path: ~p"/admin/dashboard",
        requires: :player
      },
      %Page{
        key: :settings,
        hub: :system,
        label: "Settings",
        description: "Runtime server settings",
        icon: "hero-cog-6-tooth",
        path: ~p"/admin/settings"
      },
      %Page{
        key: :users,
        hub: :system,
        label: "Users",
        description: "Accounts, roles and sign-in",
        icon: "hero-users",
        path: ~p"/admin/users"
      },
      %Page{
        key: :api_keys,
        hub: :system,
        label: "API Keys",
        description: "Keys for the library API and automation",
        icon: "hero-key",
        path: ~p"/admin/api-keys"
      },
      %Page{
        key: :remote_access,
        hub: :system,
        label: "Remote Access",
        description: "Reach this server from the player outside your network",
        icon: "hero-signal",
        path: ~p"/admin/remote-access",
        requires: :player
      },
      %Page{
        key: :plugins,
        hub: :system,
        label: "Plugins",
        description: "Sandboxed extensions and their capabilities",
        icon: "hero-puzzle-piece",
        path: ~p"/admin/plugins"
      }
    ]
  end

  @doc "The pages in `hub` whose feature gate is on, in sidebar order."
  @spec visible_pages(Page.hub()) :: [Page.t()]
  def visible_pages(hub), do: Enum.filter(pages(), &(&1.hub == hub and visible?(&1)))

  @doc "Whether a page's feature gate is on."
  @spec visible?(Page.t()) :: boolean()
  def visible?(%Page{requires: nil}), do: true
  def visible?(%Page{requires: :player}), do: Mydia.Player.enabled?()
  def visible?(%Page{requires: :import_lists}), do: Mydia.ImportLists.FeatureFlags.enabled?()

  @doc "The page registered under `key`. Raises `ArgumentError` for an unknown key."
  @spec fetch!(atom()) :: Page.t()
  def fetch!(key) do
    Enum.find(pages(), &(&1.key == key)) ||
      raise ArgumentError, "unknown admin page #{inspect(key)}, expected one of #{inspect(@keys)}"
  end

  @doc "The page whose path is exactly `path`, or nil."
  @spec page_for_path(String.t() | nil) :: Page.t() | nil
  def page_for_path(nil), do: nil
  def page_for_path(path), do: Enum.find(pages(), &(&1.path == path))
end
