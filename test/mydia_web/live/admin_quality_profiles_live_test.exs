defmodule MydiaWeb.AdminQualityProfilesLiveTest do
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
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/config/quality")
      assert path =~ "/auth"
    end
  end

  describe "Quality Profiles" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/quality")
      %{conn: conn, view: view}
    end

    test "displays quality profiles section", %{view: view} do
      assert has_element?(view, "h2", "Quality Profiles")
    end

    test "displays existing quality profiles", %{conn: conn} do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "HD",
          upgrades_allowed: true,
          upgrade_until_quality: "1080p",
          quality_standards: %{
            preferred_resolutions: ["720p", "1080p"],
            movie_min_size_mb: 1000,
            movie_max_size_mb: 5000,
            preferred_sources: []
          }
        })

      {:ok, _view, html} = live(conn, ~p"/admin/config/quality")

      assert html =~ "HD"
    end

    test "opens modal when clicking new profile button", %{view: view} do
      view
      |> element(~s{button[phx-click="new_quality_profile"]})
      |> render_click()

      assert has_element?(view, ~s{div[class*="modal-open"]})
      assert has_element?(view, "h3", "New Quality Profile")
    end

    test "creates a new quality profile", %{view: view} do
      view
      |> element(~s{button[phx-click="new_quality_profile"]})
      |> render_click()

      view
      |> form("#quality-profile-form",
        quality_profile: %{
          "name" => "4K Ultra HD",
          "quality_standards" => %{"preferred_resolutions" => ["2160p", "1080p"]}
        }
      )
      |> render_submit()

      html = render(view)
      assert html =~ "4K Ultra HD"
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end

    test "validates quality profile form", %{view: view} do
      view
      |> element(~s{button[phx-click="new_quality_profile"]})
      |> render_click()

      html =
        view
        |> form("#quality-profile-form", quality_profile: %{name: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "default selector renders \"None (no default)\" when nothing is configured", %{
      conn: conn
    } do
      {:ok, _} = Settings.set_default_quality_profile(nil)

      {:ok, view, _html} = live(conn, ~p"/admin/config/quality")

      assert has_element?(
               view,
               ~s{#default-quality-profile-select option[value=""]},
               "None (no default)"
             )
    end

    test "default selector never interpolates a profile name, even when a default is configured",
         %{conn: conn} do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Custom-#{System.unique_integer([:positive])}",
          quality_standards: %{preferred_resolutions: ["1080p"]}
        })

      {:ok, _} = Settings.set_default_quality_profile(profile.id)

      {:ok, view, _html} = live(conn, ~p"/admin/config/quality")

      assert has_element?(
               view,
               ~s{#default-quality-profile-select option[value=""]},
               "None (no default)"
             )

      refute has_element?(
               view,
               ~s{#default-quality-profile-select option[value=""]},
               profile.name
             )
    end
  end
end
