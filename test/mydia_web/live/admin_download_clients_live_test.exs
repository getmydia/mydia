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
      assert has_element?(view, "#delete-download-client-modal", "1 download is still waiting")
    end

    test "the delete warning counts only downloads that are still waiting", %{conn: conn} do
      # More than one reference, because a count of 1 cannot tell a correct
      # count from an inflated one. Imported rows are not deleted after import
      # (`MediaImport` stamps `imported_at` and the row stays as history), so
      # on a mature instance they dominate any count that includes them, while
      # deleting the client does nothing whatsoever to them.
      {:ok, client} =
        Mydia.Settings.create_download_client_config(%{
          name: "qbit-mature",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true
        })

      media_item = Mydia.MediaFixtures.media_item_fixture()

      for _ <- 1..2 do
        Mydia.DownloadsFixtures.download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-mature"
        })
      end

      for _ <- 1..3 do
        Mydia.DownloadsFixtures.download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-mature",
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
      end

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")

      view
      |> element("#delete-download-client-#{client.id}")
      |> render_click()

      assert has_element?(view, "#delete-download-client-modal", "2 downloads are still waiting")
      refute has_element?(view, "#delete-download-client-modal", "5 downloads")
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

    test "a second delete click is a no-op rather than a crash", %{conn: conn} do
      {:ok, client} =
        Mydia.Settings.create_download_client_config(%{
          name: "qbit-doubleclick",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/clients")

      view |> element("#delete-download-client-#{client.id}") |> render_click()
      view |> element("#confirm-delete-download-client") |> render_click()

      # The modal is gone and pending_delete_client is nil now. A second
      # "delete_download_client" event, as a fast double-click would send
      # before the DOM re-renders, must not reach
      # Settings.delete_download_client_config/1 with nil and crash the
      # LiveView process.
      assert render_click(view, "delete_download_client", %{}) =~ "Download Clients"

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

      assert has_element?(
               view,
               "#delete-download-client-modal",
               "No downloads are waiting on this client."
             )
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

    test "the stalled timeout field spells out both thresholds", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      html = render(view)

      # The default of 60 means flagged at 1h and given up on at 4h total. The
      # second number is the one that destroys something, and it was previously
      # invisible everywhere in the UI.
      assert html =~ "Flagged as stalled after 1h"
      assert html =~ "4h total"
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

  describe "Form: External torrents" do
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

    defp open_new_client_form(view) do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()
    end

    defp change_type(view, type) do
      view
      |> form("#download-client-form", %{"download_client_config" => %{"type" => type}})
      |> render_change()
    end

    # The mode select is type-aware. `category_only` is meaningless for rqbit,
    # which has neither categories nor labels, so it is not offered at all
    # rather than offered and left to adopt nothing in silence.
    test "offers every mode for a qbittorrent client", %{view: view} do
      open_new_client_form(view)

      assert has_element?(view, "#download-client-external-torrents")

      html = change_type(view, "qbittorrent")
      assert html =~ "External torrents"
      assert html =~ "category_only"
      assert html =~ "ignore"
    end

    test "omits category_only for rqbit", %{view: view} do
      open_new_client_form(view)

      html = change_type(view, "rqbit")

      # The control is still there, minus the one option rqbit cannot satisfy.
      assert html =~ "External torrents"
      refute html =~ "category_only"
    end

    test "hides the control entirely for a client type the scan never visits", %{view: view} do
      open_new_client_form(view)

      # Usenet clients have no concept of a foreign torrent sitting in them.
      html = change_type(view, "sabnzbd")

      refute html =~ "External torrents"
    end
  end

  describe "Wave-2 Form: Remote seedbox (Test SFTP Connection)" do
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

    test "the button stays disabled until an SFTP host is entered", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      view
      |> form("#download-client-form", %{
        "download_client_config" => %{"type" => "qbittorrent"}
      })
      |> render_change()

      assert has_element?(view, ~s{button[phx-click="test_seedbox_connection"][disabled]})

      view
      |> form("#download-client-form", %{
        "download_client_config" => %{
          "type" => "qbittorrent",
          "connection_settings" => %{
            "remote_fetch" => %{"host" => "seedbox.example.com"}
          }
        }
      })
      |> render_change()

      refute has_element?(view, ~s{button[phx-click="test_seedbox_connection"][disabled]})
    end

    test "reports a connection failure via flash for an unreachable host", %{view: view} do
      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      view
      |> form("#download-client-form", %{
        "download_client_config" => %{
          "type" => "qbittorrent",
          "connection_settings" => %{
            "remote_fetch" => %{
              "enabled" => "true",
              "host" => "127.0.0.1",
              "port" => "1",
              "username" => "u",
              "auth_method" => "password",
              "password" => "p"
            }
          }
        }
      })
      |> render_change()

      html =
        view
        |> element(~s{button[phx-click="test_seedbox_connection"]})
        |> render_click()

      assert html =~ "SFTP connection failed"
    end

    test "reports success via flash for a reachable SFTP host", %{view: view} do
      root =
        Path.join(System.tmp_dir!(), "seedbox_ui_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      {daemon_ref, port} = Mydia.SftpFixture.start(root, "seeduser", "seedpass")
      on_exit(fn -> :ssh.stop_daemon(daemon_ref) end)

      view
      |> element(~s{button[phx-click="new_download_client"]})
      |> render_click()

      view
      |> form("#download-client-form", %{
        "download_client_config" => %{
          "type" => "qbittorrent",
          "connection_settings" => %{
            "remote_fetch" => %{
              "enabled" => "true",
              "host" => "127.0.0.1",
              # Submitted as a string, same as a real HTML number input —
              # exercises Connection.open/1's string-port normalization.
              "port" => to_string(port),
              "username" => "seeduser",
              "auth_method" => "password",
              "password" => "seedpass"
            }
          }
        }
      })
      |> render_change()

      html =
        view
        |> element(~s{button[phx-click="test_seedbox_connection"]})
        |> render_click()

      assert html =~ "SFTP connection successful"
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
