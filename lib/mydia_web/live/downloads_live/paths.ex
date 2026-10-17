defmodule MydiaWeb.DownloadsLive.Paths do
  @moduledoc """
  Builds Downloads page URLs and the tab bar entries from the page's assigns.
  """

  use MydiaWeb, :verified_routes

  alias MydiaWeb.DownloadsLive.Tab

  # Builds /downloads?... from the current state with `overrides` applied.
  # Defaults (Downloads tab, Active view, nil values) are left out so links
  # stay short.
  @spec downloads_path(map(), keyword() | map()) :: String.t()
  def downloads_path(assigns, overrides) do
    %{active_tab: tab, view: view, drawer_id: drawer_id, filters: filters} = assigns

    values =
      Map.merge(
        %{
          tab: tab,
          view: view,
          q: filters.q,
          client: filters.client,
          status: filters.status,
          download: drawer_id
        },
        Map.new(overrides)
      )

    # Fixed key order, so the same state always produces the same URL.
    params =
      [:tab, :view, :q, :client, :status, :download]
      |> Enum.map(&{&1, values[&1]})
      |> Enum.reject(fn {key, value} ->
        is_nil(value) or {key, value} in [{:tab, :downloads}, {:view, :active}]
      end)
      |> Enum.map(fn {key, value} -> {key, to_string(value)} end)

    case params do
      [] -> ~p"/downloads"
      params -> ~p"/downloads?#{params}"
    end
  end

  # Tab links keep the search and client, and drop the view, the status and
  # the open drawer: none of them carries over to another tab.
  @spec tabs(map()) :: [Tab.t()]
  def tabs(assigns) do
    href = &downloads_path(assigns, tab: &1, view: nil, status: nil, download: nil)

    [
      %Tab{
        key: :downloads,
        label: "Downloads",
        icon: "hero-arrow-down-tray",
        href: href.(:downloads),
        count: assigns.tab_counts.downloads,
        dot?: assigns.summary.stalled > 0
      },
      %Tab{
        key: :issues,
        label: "Issues",
        icon: "hero-exclamation-triangle",
        href: href.(:issues),
        count: assigns.tab_counts.issues,
        tone: :error
      },
      # Neutral on purpose: unmanaged torrents are not problems.
      %Tab{
        key: :external,
        label: "External",
        icon: "hero-inbox-stack",
        href: href.(:external),
        count: length(assigns.scan.external)
      }
    ]
  end
end
