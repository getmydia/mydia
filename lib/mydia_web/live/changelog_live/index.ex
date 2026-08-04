defmodule MydiaWeb.ChangelogLive.Index do
  @moduledoc """
  Release notes bundled into this build, newest first.

  Visiting the page counts as reading it, so it performs the same write as
  dismissing the banner, and clears the banner for this mount.

  The write is guarded on `connected?/1` deliberately. `mount/3` runs twice, once
  for the dead render and again for the connected socket. Writing during the dead
  render would mean the connected render re-reads the value it just wrote, finds
  nothing unseen, and drops every "New" badge the user came here to see.
  """
  use MydiaWeb, :live_view

  alias Mydia.Accounts
  alias Mydia.Changelog

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    unseen_versions =
      user
      |> Accounts.last_seen_changelog_version()
      |> Changelog.unseen()
      |> MapSet.new(& &1.version_string)

    if connected?(socket) do
      case Changelog.latest() do
        nil -> :ok
        latest -> Accounts.mark_changelog_seen(user, latest)
      end
    end

    {:ok,
     socket
     |> assign(:page_title, "What's new")
     |> assign(:entries, Changelog.entries())
     |> assign(:unseen_versions, unseen_versions)
     |> assign(:changelog_notice, nil)}
  end

  @doc """
  DOM id for an entry, stable across renders and used by tests.
  """
  def entry_id(version_string) do
    "changelog-entry-" <> String.replace(version_string, ".", "-")
  end
end
