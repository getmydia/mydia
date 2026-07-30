defmodule MydiaWeb.AdminDownloadClientsLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Mydia.{Accounts, Settings}

  setup do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    %{user: user, token: token}
  end

  describe "Authentication" do
    test "redirects unauthenticated users", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/config/clients")
      assert path =~ "/auth"
    end
  end

  describe "Download Clients" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")
      %{conn: conn, view: view}
    end

    test "displays empty state when no clients exist", %{conn: conn, token: token} do
      Mydia.Settings.list_download_client_configs()
      |> Enum.each(fn client_config ->
        unless is_binary(client_config.id) and String.starts_with?(client_config.id, "runtime::") do
          Mydia.Settings.delete_download_client_config(client_config)
        end
      end)

      Mydia.Downloads.Client.Registry.unregister(:transmission)
      # Resolution sites now depend on the Registry; restore it after this test.
      on_exit(fn -> Mydia.Downloads.register_clients() end)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, _view, html} = live(conn, ~p"/admin/config/clients")
      assert html =~ "Download Clients"
    end

    test "warns about referencing downloads before deleting a client", %{conn: conn} do
      {:ok, client} =
        Mydia.Settings.create_download_client_config(%{
          name: "qbit-doomed",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true
        })

      media_item = Mydia.MediaFixtures.media_item_fixture()

      Mydia.DownloadsFixtures.download_fixture(%{
        media_item_id: media_item.id,
        download_client: "qbit-doomed"
      })

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")

      view
      |> element("#delete-download-client-#{client.id}")
      |> render_click()

      assert has_element?(view, "#delete-download-client-modal")
      assert render(view) =~ "1 download"
    end

    test "deletes the client after the warning is confirmed", %{conn: conn} do
      {:ok, client} =
        Mydia.Settings.create_download_client_config(%{
          name: "qbit-doomed-2",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")

      view |> element("#delete-download-client-#{client.id}") |> render_click()
      view |> element("#confirm-delete-download-client") |> render_click()

      assert_raise Ecto.NoResultsError, fn ->
        Mydia.Settings.get_download_client_config!(client.id)
      end
    end

    test "shows a plain zero-reference message when no downloads reference the client", %{
      conn: conn
    } do
      {:ok, client} =
        Mydia.Settings.create_download_client_config(%{
          name: "qbit-unused",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")

      view
      |> element("#delete-download-client-#{client.id}")
      |> render_click()

      assert has_element?(view, "#delete-download-client-modal")
      assert render(view) =~ "No downloads reference this client."
    end

    test "cancelling the delete warning leaves the client intact", %{conn: conn} do
      {:ok, client} =
        Mydia.Settings.create_download_client_config(%{
          name: "qbit-keep",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")

      view |> element("#delete-download-client-#{client.id}") |> render_click()
      assert has_element?(view, "#delete-download-client-modal")

      view |> element("#cancel-delete-download-client") |> render_click()

      refute has_element?(view, "#delete-download-client-modal")
      assert Mydia.Settings.get_download_client_config!(client.id)
    end

    test "creates a new download client", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      view
      |> form("#download-client-form",
        download_client_config: %{
          name: "qBittorrent",
          type: "qbittorrent",
          host: "localhost",
          port: "8080",
          username: "admin",
          password: "password",
          enabled: "true",
          priority: "1"
        }
      )
      |> render_submit()

      html = render(view)
      assert html =~ "qBittorrent"
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end
  end

  describe "Wave-2 Form: Categories" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")
      %{conn: conn, view: view}
    end

    test "submitting per-content-type categories saves them as a map", %{view: view} do
      name = "qbittorrent_cats_#{System.unique_integer([:positive])}"

      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      view
      |> form("#download-client-form", %{
        "download_client_config" => %{
          "name" => name,
          "type" => "qbittorrent",
          "host" => "localhost",
          "port" => "8080",
          "enabled" => "true",
          "priority" => "1",
          "categories" => %{
            "movie" => "movies",
            "tv" => "tv",
            "music" => ""
          }
        }
      })
      |> render_submit()

      refute has_element?(view, ~s{div[class*="modal-open"]})

      saved = Enum.find(Settings.list_download_client_configs(), &(&1.name == name))
      assert saved, "expected to find saved client #{name}"
      assert saved.categories["movie"] == "movies"
      assert saved.categories["tv"] == "tv"
      refute Map.has_key?(saved.categories, "music")
    end

    test "blackhole client does not render category inputs", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      view
      |> form("#download-client-form", %{
        "download_client_config" => %{"type" => "blackhole"}
      })
      |> render_change()

      refute has_element?(view, "#download-client-categories")
      refute has_element?(view, "#download-client-priority-profile")
    end

    test "debrid type renders provider sub-selector and hides host/port/categories", %{
      view: view
    } do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      html =
        view
        |> form("#download-client-form", %{
          "download_client_config" => %{"type" => "debrid"}
        })
        |> render_change()

      # Provider sub-selector is visible (under connection_settings[provider])
      assert html =~ "Debrid Service"
      assert html =~ "real_debrid"
      assert html =~ "all_debrid"
      assert html =~ "premiumize"
      assert html =~ "tor_box"

      # Categories and priority-profile blocks are hidden for debrid.
      refute has_element?(view, "#download-client-categories")
      refute has_element?(view, "#download-client-priority-profile")
    end

    test "Debrid option appears in the type select", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      html = render(view)
      assert html =~ ~s{value="debrid"}
      assert html =~ "Debrid"
    end

    test "rqbit option appears in the type select", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      html = render(view)
      assert html =~ ~s{value="rqbit"}
    end

    test "rqbit type renders host/port fields and hides categories", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      html =
        view
        |> form("#download-client-form", %{
          "download_client_config" => %{"type" => "rqbit"}
        })
        |> render_change()

      # rqbit is a standard network client: host/port are rendered.
      assert html =~ "Host"
      assert html =~ "Port"

      # rqbit has no category or priority-profile concept.
      refute has_element?(view, "#download-client-categories")
      refute has_element?(view, "#download-client-priority-profile")
    end

    test "legacy single-category clients prefill all three content-type inputs", %{conn: conn} do
      {:ok, legacy_client} =
        Settings.create_download_client_config(%{
          "name" => "legacy_#{System.unique_integer([:positive])}",
          "type" => "qbittorrent",
          "host" => "localhost",
          "port" => "8080",
          "enabled" => "true",
          "priority" => "1",
          "category" => "all"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")

      view
      |> element(~s{button[phx-click="edit_download_client"][phx-value-id="#{legacy_client.id}"]})
      |> render_click()

      html = render(view)
      assert html =~ ~s{id="download-client-categories"}
      # All three slots prefilled with the legacy value
      assert html =~ ~s{value="all"}
    end
  end

  describe "Wave-2 Form: Priority profile" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")
      %{conn: conn, view: view}
    end

    test "priority profile values round-trip through the form", %{view: view} do
      name = "sab_prio_#{System.unique_integer([:positive])}"

      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      view
      |> form("#download-client-form", %{
        "download_client_config" => %{
          "name" => name,
          "type" => "sabnzbd",
          "host" => "localhost",
          "port" => "8080",
          "enabled" => "true",
          "priority" => "1",
          "priority_profile" => %{
            "verylow" => "-100",
            "normal" => "0",
            "veryhigh" => "2",
            "low" => "",
            "high" => ""
          }
        }
      })
      |> render_submit()

      refute has_element?(view, ~s{div[class*="modal-open"]})

      saved = Enum.find(Settings.list_download_client_configs(), &(&1.name == name))
      assert saved, "expected to find saved client #{name}"
      assert saved.priority_profile["verylow"] == "-100"
      assert saved.priority_profile["normal"] == "0"
      assert saved.priority_profile["veryhigh"] == "2"
      refute Map.has_key?(saved.priority_profile, "low")
      refute Map.has_key?(saved.priority_profile, "high")
    end

    test "priority profile section is hidden for blackhole clients", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      view
      |> form("#download-client-form", %{
        "download_client_config" => %{"type" => "blackhole"}
      })
      |> render_change()

      refute has_element?(view, "#download-client-priority-profile")
    end

    test "priority profile section is visible for qBittorrent", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      assert has_element?(view, "#download-client-priority-profile")
    end
  end

  describe "Wave-2 Form: Stalled timeout" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")
      %{conn: conn, view: view}
    end

    test "shows inline validation error for non-positive incomplete_grace_minutes", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      html =
        view
        |> form("#download-client-form", %{
          "download_client_config" => %{
            "name" => "stalled_neg",
            "type" => "qbittorrent",
            "host" => "localhost",
            "port" => "8080",
            "enabled" => "true",
            "priority" => "1",
            "incomplete_grace_minutes" => "-5"
          }
        })
        |> render_change()

      assert html =~ "must be greater than 0"
    end

    test "stalled timeout input is visible for blackhole clients too", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      view
      |> form("#download-client-form", %{
        "download_client_config" => %{"type" => "blackhole"}
      })
      |> render_change()

      assert has_element?(view, "#download-client-grace-minutes")
    end
  end

  describe "Runtime Config Protection" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "runtime_config?/1 identifies runtime configs correctly" do
      runtime_client = %Mydia.Settings.DownloadClientConfig{
        id: "runtime::download_client::Test Client"
      }

      assert Settings.runtime_config?(runtime_client) == true

      db_client = %Mydia.Settings.DownloadClientConfig{
        id: Ecto.UUID.generate()
      }

      assert Settings.runtime_config?(db_client) == false

      int_client = %Mydia.Settings.DownloadClientConfig{
        id: 123
      }

      assert Settings.runtime_config?(int_client) == false
    end

    test "template shows disabled buttons for runtime configs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/config/clients")

      if html =~ "runtime::download_client" do
        assert html =~ "Cannot edit runtime-configured clients"
        assert html =~ "Cannot delete runtime-configured clients"
      end
    end

    test "template shows ENV badge for runtime configs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/config/clients")

      if html =~ "runtime::download_client" do
        assert html =~ "ENV"
        assert html =~ "Configured via environment variables"
      end
    end
  end
end
