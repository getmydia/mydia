defmodule MydiaWeb.ProfileLiveTest do
  # async: false — connected LiveView under the Postgres sandbox (rows inserted
  # in the test must be visible to the mount process).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "renders the profile page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    assert has_element?(view, "#profile-form")
  end

  test "links out to the dedicated Integrations page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    # Integrations moved to /integrations; the profile page only points to it.
    assert has_element?(view, "#integrations-link[href='/integrations']")
  end

  test "the mode picker defaults to System", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    assert has_element?(
             view,
             "#theme-picker button[phx-value-mode='system'][aria-pressed='true']"
           )

    assert has_element?(view, "#theme-picker button[phx-value-mode='dark'][aria-pressed='false']")
  end

  test "choosing Dark moves the selection, persists it and pushes the client event",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view |> element("#theme-picker button[phx-value-mode='dark']") |> render_click()

    # Server-rendered from @theme_selection, which the shared hook updates.
    assert has_element?(view, "#theme-picker button[phx-value-mode='dark'][aria-pressed='true']")
    assert has_element?(view, "#dark-theme-gallery [data-role='in-use']")
    refute has_element?(view, "#light-theme-gallery [data-role='in-use']")
    assert user |> Accounts.get_user_preference!() |> UserPreference.theme() == "dark"
    assert_push_event(view, "theme_changed", %{mode: "dark"})
  end

  test "galleries list each scheme's themes with the defaults selected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    for theme <- Mydia.Accounts.Themes.light() do
      assert has_element?(view, "#light-theme-gallery-#{theme.id}")
    end

    for theme <- Mydia.Accounts.Themes.dark() do
      assert has_element?(view, "#dark-theme-gallery-#{theme.id}")
    end

    assert has_element?(view, "#light-theme-gallery-mydia-light input[checked]")
    assert has_element?(view, "#dark-theme-gallery-mydia-dark input[checked]")
    refute has_element?(view, "#light-theme-gallery-dracula")
  end

  test "picking a gallery card saves that slot", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view |> element("#dark-theme-gallery-dracula input") |> render_click()

    assert has_element?(view, "#dark-theme-gallery-dracula input[checked]")
    selection = user |> Accounts.get_user_preference!() |> UserPreference.theme_selection()
    assert selection.dark.id == "dracula"
    assert_push_event(view, "theme_changed", %{dark_theme: "dracula"})
  end

  test "the corners picker defaults to Theme and saves a preset", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    assert has_element?(view, "#theme-radius-picker")
    assert has_element?(view, "#theme-radius-theme[checked]")

    view |> element("#theme-radius-sharp") |> render_click()

    assert has_element?(view, "#theme-radius-sharp[checked]")
    refute has_element?(view, "#theme-radius-theme[checked]")
    selection = user |> Accounts.get_user_preference!() |> UserPreference.theme_selection()
    assert selection.radius == "sharp"
    assert_push_event(view, "theme_changed", %{radius: "sharp"})
  end

  test "a theme change is not undone by a later profile save", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/profile")

    view |> element("#dark-theme-gallery-dracula input") |> render_click()
    render_hook(view, "update_add_defaults", %{"add_monitored" => "true"})

    selection = user |> Accounts.get_user_preference!() |> UserPreference.theme_selection()
    assert selection.dark.id == "dracula"
  end

  describe "avatar upload and management" do
    test "renders avatar upload input and remove button when avatar exists", %{
      conn: conn,
      user: user
    } do
      {:ok, _user} =
        Accounts.update_profile(user, %{avatar_url: "https://example.com/avatar.jpg"})

      {:ok, view, html} = live(conn, ~p"/profile")

      assert has_element?(view, "input[type='file'][name*='avatar']")
      assert has_element?(view, "#remove-avatar-btn")
      assert html =~ "Remove Avatar"
    end

    test "does not render remove avatar button when user has no avatar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profile")
      refute has_element?(view, "#remove-avatar-btn")
    end

    test "removes avatar when clicking Remove Avatar button", %{conn: conn, user: user} do
      {:ok, _user} =
        Accounts.update_profile(user, %{avatar_url: "https://example.com/avatar.jpg"})

      {:ok, view, _html} = live(conn, ~p"/profile")

      view
      |> element("#remove-avatar-btn")
      |> render_click()

      assert render(view) =~ "Avatar removed"
      refute has_element?(view, "#remove-avatar-btn")

      reloaded_user = Accounts.get_user!(user.id)
      assert is_nil(reloaded_user.avatar_url)
    end

    test "removes local avatar file from disk when clicking Remove Avatar button", %{
      conn: conn,
      user: user
    } do
      dir = Mydia.Accounts.Avatar.storage_dir()
      File.mkdir_p!(dir)
      filename = "avatar-#{user.id}-12345.png"
      file_path = Path.join(dir, filename)
      File.write!(file_path, "fake png content")

      {:ok, _user} =
        Accounts.update_profile(user, %{avatar_url: "/generated/avatars/#{filename}"})

      assert File.exists?(file_path)

      {:ok, view, _html} = live(conn, ~p"/profile")

      view
      |> element("#remove-avatar-btn")
      |> render_click()

      assert render(view) =~ "Avatar removed"
      refute File.exists?(file_path)
    end

    test "uploads an avatar image file and updates profile", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      png_data =
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
          6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5,
          0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

      avatar =
        file_input(view, "#profile-form", :avatar, [
          %{
            name: "avatar.png",
            content: png_data,
            type: "image/png"
          }
        ])

      render_upload(avatar, "avatar.png")

      view
      |> form("#profile-form", %{"user" => %{"display_name" => "Avatar Tester"}})
      |> render_submit()

      assert render(view) =~ "Profile updated successfully"

      updated_user = Accounts.get_user!(user.id)
      assert String.starts_with?(updated_user.avatar_url, "/generated/avatars/avatar-#{user.id}-")
      assert String.ends_with?(updated_user.avatar_url, ".png")
      assert updated_user.display_name == "Avatar Tester"
    end

    test "cancels an avatar upload in progress", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      png_data =
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
          6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5,
          0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

      avatar =
        file_input(view, "#profile-form", :avatar, [
          %{
            name: "avatar.png",
            content: png_data,
            type: "image/png"
          }
        ])

      assert {:ok, _} = preflight_upload(avatar)
      assert has_element?(view, "button[phx-click='cancel_avatar_upload']")

      view
      |> element("button[phx-click='cancel_avatar_upload']")
      |> render_click()

      refute has_element?(view, "button[phx-click='cancel_avatar_upload']")
    end

    test "cancelling an upload then saving profile does not change avatar", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/profile")

      png_data =
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
          6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5,
          0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

      avatar =
        file_input(view, "#profile-form", :avatar, [
          %{
            name: "avatar.png",
            content: png_data,
            type: "image/png"
          }
        ])

      assert {:ok, _} = preflight_upload(avatar)

      view
      |> element("button[phx-click='cancel_avatar_upload']")
      |> render_click()

      view
      |> form("#profile-form", %{"user" => %{"display_name" => "No Upload Tester"}})
      |> render_submit()

      assert render(view) =~ "Profile updated successfully"
      updated_user = Accounts.get_user!(user.id)
      assert updated_user.display_name == "No Upload Tester"
      assert is_nil(updated_user.avatar_url)
    end

    test "shows upload error for unacceptable file format", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      avatar =
        file_input(view, "#profile-form", :avatar, [
          %{
            name: "malicious.exe",
            content: "executable binary",
            type: "application/x-msdownload"
          }
        ])

      assert {:error, [[_, :not_accepted]]} = preflight_upload(avatar)
      assert render(view) =~ "Unacceptable file type"
    end

    test "avatar URL input uses type text and leaves field blank for local generated avatars", %{
      conn: conn,
      user: user
    } do
      {:ok, user} =
        Accounts.update_profile(user, %{
          avatar_url: "/generated/avatars/avatar-#{user.id}-123.png"
        })

      {:ok, view, _html} = live(conn, ~p"/profile")

      assert has_element?(view, "input[type='text'][name*='avatar_url']")
      refute has_element?(view, "input[type='url'][name*='avatar_url']")

      avatar_input = element(view, "input[name*='avatar_url']")
      assert render(avatar_input) =~ ~s(value="")

      view
      |> form("#profile-form", %{
        "user" => %{"display_name" => "Updated Name", "avatar_url" => ""}
      })
      |> render_submit()

      assert render(view) =~ "Profile updated successfully"
      reloaded = Accounts.get_user!(user.id)
      assert reloaded.display_name == "Updated Name"
      assert reloaded.avatar_url == "/generated/avatars/avatar-#{user.id}-123.png"
    end

    test "cleans up old local avatar file on disk when replacing with an external URL", %{
      conn: conn,
      user: user
    } do
      dir = Mydia.Accounts.Avatar.storage_dir()
      File.mkdir_p!(dir)
      filename = "avatar-#{user.id}-to-replace.png"
      file_path = Path.join(dir, filename)
      File.write!(file_path, "local avatar data")

      {:ok, user} =
        Accounts.update_profile(user, %{avatar_url: "/generated/avatars/#{filename}"})

      assert File.exists?(file_path)

      {:ok, view, _html} = live(conn, ~p"/profile")

      view
      |> form("#profile-form", %{
        "user" => %{
          "display_name" => user.display_name || "User",
          "avatar_url" => "https://example.com/external-avatar.jpg"
        }
      })
      |> render_submit()

      assert render(view) =~ "Profile updated successfully"
      refute File.exists?(file_path)

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.avatar_url == "https://example.com/external-avatar.jpg"
    end

    test "does not write avatar file to disk if profile validation fails", %{
      conn: conn,
      user: user
    } do
      dir = Mydia.Accounts.Avatar.storage_dir()
      File.mkdir_p!(dir)

      Path.wildcard(Path.join(dir, "avatar-#{user.id}-*"))
      |> Enum.each(&File.rm/1)

      {:ok, view, _html} = live(conn, ~p"/profile")

      png_data =
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
          6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5,
          0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

      avatar =
        file_input(view, "#profile-form", :avatar, [
          %{
            name: "avatar.png",
            content: png_data,
            type: "image/png"
          }
        ])

      render_upload(avatar, "avatar.png")

      too_long_name = String.duplicate("a", 101)

      view
      |> form("#profile-form", %{"user" => %{"display_name" => too_long_name}})
      |> render_submit()

      assert render(view) =~ "should be at most 100 character(s)"
      refute render(view) =~ "Profile updated successfully"

      written_files = Path.wildcard(Path.join(dir, "avatar-#{user.id}-*"))
      assert written_files == []

      reloaded = Accounts.get_user!(user.id)
      assert is_nil(reloaded.avatar_url)
    end

    test "sidebar user menu renders avatar image when user has avatar_url", %{
      conn: conn,
      user: user
    } do
      avatar_url = "https://example.com/user-avatar.jpg"
      {:ok, _user} = Accounts.update_profile(user, %{avatar_url: avatar_url})

      {:ok, view, _html} = live(conn, ~p"/profile")

      assert has_element?(view, "#sidebar-user-menu img[src='#{avatar_url}']")
    end

    test "sidebar user menu falls back to initials when user has no avatar_url", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/profile")

      refute has_element?(view, "#sidebar-user-menu img")
      initials = String.upcase(String.slice(user.username || user.email, 0..1))
      assert has_element?(view, "#sidebar-user-menu span", initials)
    end
  end
end
