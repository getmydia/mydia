defmodule MydiaWeb.AdminNav do
  @moduledoc """
  Every admin page: its hub, icon and path, plus its label and one-line
  description through `page_label/1` and `page_description/1`.

  This one list drives the sidebar's Admin section, the header each admin page
  renders, and which legacy `/admin/config/*` URLs redirect. A new admin page
  needs an entry here; `test/mydia_web/admin_nav_test.exs` fails for a live route
  under `/admin` that has none.

  Hubs: **Configuration** holds acquisition levers, **Administration** holds work
  an operator has to act on, **System** holds the server itself.
  """

  use MydiaWeb, :verified_routes
  use Gettext, backend: MydiaWeb.Gettext

  alias MydiaWeb.AdminNav.Page

  # Labels are functions (hub_label/1, page_label/1), never data: a module
  # attribute is evaluated at compile time, before any locale is set.
  @hubs [
    %{key: :configuration, icon: "hero-adjustments-horizontal"},
    %{key: :administration, icon: "hero-clipboard-document-check"},
    %{key: :system, icon: "hero-server"}
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
    :media_servers,
    :storage_backends,
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
  @spec hubs() :: [%{key: Page.hub(), icon: String.t()}]
  def hubs, do: @hubs

  @doc "The translated label of `hub`."
  @spec hub_label(Page.hub()) :: String.t()
  def hub_label(:configuration), do: gettext("Configuration")
  def hub_label(:administration), do: gettext("Administration")
  def hub_label(:system), do: gettext("System")

  @doc "The translated label of a page, given its `Page` or its key."
  @spec page_label(Page.t() | atom()) :: String.t()
  def page_label(%Page{key: key}), do: page_label(key)
  def page_label(:quality), do: gettext("Quality")
  def page_label(:custom_formats), do: gettext("Custom Formats")
  def page_label(:clients), do: gettext("Clients")
  def page_label(:indexers), do: gettext("Indexers")
  def page_label(:library_paths), do: gettext("Library")
  def page_label(:path_mappings), do: gettext("Path Mappings")
  def page_label(:subtitle_providers), do: gettext("Subtitle Providers")
  def page_label(:media_servers), do: gettext("Media Servers")
  def page_label(:storage_backends), do: gettext("Storage")
  def page_label(:requests), do: gettext("Requests")
  def page_label(:jobs), do: gettext("Background Jobs")
  def page_label(:release_blacklist), do: gettext("Release Blacklist")
  def page_label(:duplicates), do: gettext("Duplicates")
  def page_label(:trash), do: gettext("Trash")
  def page_label(:status), do: gettext("Status")
  def page_label(:dashboard), do: gettext("Dashboard")
  def page_label(:settings), do: gettext("Settings")
  def page_label(:users), do: gettext("Users")
  def page_label(:api_keys), do: gettext("API Keys")
  def page_label(:remote_access), do: gettext("Remote Access")
  def page_label(:plugins), do: gettext("Plugins")

  @doc "The translated one-line description of a page, given its `Page` or its key."
  @spec page_description(Page.t() | atom()) :: String.t()
  def page_description(%Page{key: key}), do: page_description(key)

  def page_description(:quality),
    do: gettext("Profiles that decide which releases get grabbed and upgraded")

  def page_description(:custom_formats), do: gettext("Rules that score releases")
  def page_description(:clients), do: gettext("Torrent, Usenet and debrid download clients")
  def page_description(:indexers), do: gettext("Where searches look for releases")
  def page_description(:library_paths), do: gettext("Library folders for movies and TV")

  def page_description(:path_mappings),
    do: gettext("Translate download client paths to paths this server sees")

  def page_description(:subtitle_providers),
    do: gettext("Where subtitles are searched and downloaded")

  def page_description(:media_servers),
    do: gettext("Plex and Jellyfin refresh and watched-status sync")

  def page_description(:storage_backends),
    do: gettext("S3-compatible buckets that libraries can live in")

  def page_description(:requests), do: gettext("Approve or reject media requests from guests")
  def page_description(:jobs), do: gettext("Scheduled jobs and execution history")
  def page_description(:release_blacklist), do: gettext("Releases blocked from future searches")
  def page_description(:duplicates), do: gettext("Items with more than one file to review")
  def page_description(:trash), do: gettext("Deleted files waiting to be purged")
  def page_description(:status), do: gettext("Server, database and service health")
  def page_description(:dashboard), do: gettext("Playback activity and active sessions")
  def page_description(:settings), do: gettext("Runtime server settings")
  def page_description(:users), do: gettext("Accounts, roles and sign-in")
  def page_description(:api_keys), do: gettext("Keys for the library API and automation")

  def page_description(:remote_access),
    do: gettext("Reach this server from the player outside your network")

  def page_description(:plugins), do: gettext("Sandboxed extensions and their capabilities")

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
        icon: "hero-sparkles",
        path: ~p"/admin/quality"
      },
      %Page{
        key: :custom_formats,
        hub: :configuration,
        icon: "hero-language",
        path: ~p"/admin/custom-formats"
      },
      %Page{
        key: :clients,
        hub: :configuration,
        icon: "hero-arrow-down-tray",
        path: ~p"/admin/clients"
      },
      %Page{
        key: :indexers,
        hub: :configuration,
        icon: "hero-magnifying-glass",
        path: ~p"/admin/indexers"
      },
      %Page{
        key: :library_paths,
        hub: :configuration,
        icon: "hero-folder",
        path: ~p"/admin/library-paths"
      },
      %Page{
        key: :path_mappings,
        hub: :configuration,
        icon: "hero-arrows-right-left",
        path: ~p"/admin/path-mappings"
      },
      %Page{
        key: :subtitle_providers,
        hub: :configuration,
        icon: "hero-chat-bubble-bottom-center-text",
        path: ~p"/admin/subtitle-providers"
      },
      %Page{
        key: :media_servers,
        hub: :configuration,
        icon: "hero-server-stack",
        path: ~p"/admin/media-servers"
      },
      %Page{
        key: :storage_backends,
        hub: :configuration,
        icon: "hero-circle-stack",
        path: ~p"/admin/storage-backends"
      },
      %Page{
        key: :requests,
        hub: :administration,
        icon: "hero-inbox-stack",
        path: ~p"/admin/requests"
      },
      %Page{
        key: :jobs,
        hub: :administration,
        icon: "hero-queue-list",
        path: ~p"/admin/jobs"
      },
      %Page{
        key: :release_blacklist,
        hub: :administration,
        icon: "hero-no-symbol",
        path: ~p"/admin/release-blacklist"
      },
      %Page{
        key: :duplicates,
        hub: :administration,
        icon: "hero-document-duplicate",
        path: ~p"/admin/duplicates"
      },
      %Page{
        key: :trash,
        hub: :administration,
        icon: "hero-trash",
        path: ~p"/admin/trash"
      },
      %Page{
        key: :status,
        hub: :system,
        icon: "hero-server",
        path: ~p"/admin/status"
      },
      %Page{
        key: :dashboard,
        hub: :system,
        icon: "hero-chart-bar",
        path: ~p"/admin/dashboard",
        requires: :player
      },
      %Page{
        key: :settings,
        hub: :system,
        icon: "hero-cog-6-tooth",
        path: ~p"/admin/settings"
      },
      %Page{
        key: :users,
        hub: :system,
        icon: "hero-users",
        path: ~p"/admin/users"
      },
      %Page{
        key: :api_keys,
        hub: :system,
        icon: "hero-key",
        path: ~p"/admin/api-keys"
      },
      %Page{
        key: :remote_access,
        hub: :system,
        icon: "hero-signal",
        path: ~p"/admin/remote-access",
        requires: :player
      },
      %Page{
        key: :plugins,
        hub: :system,
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
