defmodule MydiaWeb.AdminNavTest do
  @moduledoc """
  The admin page registry that drives the sidebar, the page header and the
  legacy `/admin/config/*` redirects.
  """

  # disable_player/0 and the import-lists flag both mutate application env.
  use ExUnit.Case, async: false

  import Mydia.PlayerHelpers

  alias MydiaWeb.AdminNav
  alias MydiaWeb.AdminNav.Page

  describe "the registry" do
    test "keys/0 lists every page key in pages/0 order" do
      assert Enum.map(AdminNav.pages(), & &1.key) == AdminNav.keys()
    end

    test "keys and paths are unique" do
      pages = AdminNav.pages()

      assert pages |> Enum.uniq_by(& &1.key) |> length() == length(pages)
      assert pages |> Enum.uniq_by(& &1.path) |> length() == length(pages)
    end

    test "pages are grouped by hub, in hub order" do
      hub_keys = Enum.map(AdminNav.hubs(), & &1.key)

      assert hub_keys == [:configuration, :administration, :system]
      assert AdminNav.pages() |> Enum.map(& &1.hub) |> Enum.dedup() == hub_keys
    end

    test "every hub has a page no feature flag can hide" do
      for %{key: hub} <- AdminNav.hubs() do
        assert Enum.any?(AdminNav.pages(), &(&1.hub == hub and is_nil(&1.requires))),
               "#{hub} would render as an empty group when its gated pages are off"
      end
    end

    test "every page has a label, a one-line description and a hero icon" do
      for page <- AdminNav.pages() do
        assert page.label != ""
        assert page.description != ""
        refute page.description =~ "\n"
        assert String.starts_with?(page.icon, "hero-")
      end
    end
  end

  describe "routes" do
    test "every page path is a live route" do
      for page <- AdminNav.pages() do
        assert %{phoenix_live_view: _} =
                 Phoenix.Router.route_info(MydiaWeb.Router, "GET", page.path, "localhost"),
               "#{page.key} points at #{page.path}, which is not a live route"
      end
    end

    test "every live route under /admin is a registered page or deliberately unlisted" do
      registered = MapSet.new(AdminNav.pages(), & &1.path)

      unregistered =
        for %{path: "/admin/" <> _ = path, metadata: %{phoenix_live_view: _}} <-
              MydiaWeb.Router.__routes__(),
            path not in registered,
            not unlisted?(path),
            do: path

      assert unregistered == [],
             "add these to MydiaWeb.AdminNav, or to unlisted?/1 here: #{inspect(unregistered)}"
    end
  end

  describe "visible_pages/1" do
    test "shows player pages when the player is on" do
      keys = hub_keys(:system)

      assert :dashboard in keys
      assert :remote_access in keys
    end

    test "hides player pages when the player is off" do
      disable_player()

      keys = hub_keys(:system)

      refute :dashboard in keys
      refute :remote_access in keys
      assert :status in keys
    end

    test "hides Import Lists when its flag is off" do
      original = Application.get_env(:mydia, :features, [])
      Application.put_env(:mydia, :features, Keyword.put(original, :import_lists_enabled, false))
      on_exit(fn -> Application.put_env(:mydia, :features, original) end)

      keys = hub_keys(:configuration)

      refute :import_lists in keys
      assert :quality in keys
    end
  end

  describe "lookups" do
    test "fetch!/1 returns the page" do
      assert %Page{label: "Trash", hub: :administration, path: "/admin/trash"} =
               AdminNav.fetch!(:trash)
    end

    test "fetch!/1 raises on an unknown key" do
      assert_raise ArgumentError, fn -> AdminNav.fetch!(:not_a_page) end
    end

    test "page_for_path/1 matches whole paths only" do
      assert %Page{key: :trash} = AdminNav.page_for_path("/admin/trash")
      assert AdminNav.page_for_path("/admin/trash/extra") == nil
      assert AdminNav.page_for_path("/admin/config/trash") == nil
      assert AdminNav.page_for_path(nil) == nil
    end
  end

  defp hub_keys(hub), do: hub |> AdminNav.visible_pages() |> Enum.map(& &1.key)

  # ErrorTracker mounts its own live routes under /admin/errors, and
  # /admin/transcodes is a bare page the Dashboard already covers.
  defp unlisted?("/admin/transcodes"), do: true
  defp unlisted?("/admin/errors"), do: true
  defp unlisted?("/admin/errors/" <> _), do: true
  defp unlisted?(_path), do: false
end
