defmodule MydiaWeb.AdminQualityProfilesCustomFormatsTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Settings.CustomFormats

  setup %{conn: conn} do
    admin = admin_user_fixture()
    profile = quality_profile_fixture(%{name: "French HD"})
    %{conn: log_in_user(conn, admin), profile: profile}
  end

  test "lists every known format when editing a profile", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/quality")

    view
    |> element(~s{button[phx-click="edit_quality_profile"][phx-value-id="#{profile.id}"]})
    |> render_click()

    assert has_element?(view, "#profile-custom-formats")
    assert has_element?(view, "#custom-format-score-lang-vff")
    assert has_element?(view, "#custom-format-reject-lang-vfq")
  end

  test "saves scores and reject flags", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/quality")

    view
    |> element(~s{button[phx-click="edit_quality_profile"][phx-value-id="#{profile.id}"]})
    |> render_click()

    view
    |> form("#quality-profile-form", %{
      "quality_profile" => %{
        "name" => profile.name,
        "quality_standards" => %{"preferred_resolutions" => ["1080p"]}
      },
      "custom_formats" => %{
        "lang-vff" => %{"score" => "100", "reject" => "false"},
        "lang-vfq" => %{"score" => "0", "reject" => "true"}
      }
    })
    |> render_submit()

    assignments =
      profile
      |> CustomFormats.list_assignments()
      |> Map.new(&{&1.format_slug, &1})

    assert assignments["lang-vff"].score == 100
    refute assignments["lang-vff"].reject
    assert assignments["lang-vfq"].reject
  end

  test "an unscored format is not persisted", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/quality")

    view
    |> element(~s{button[phx-click="edit_quality_profile"][phx-value-id="#{profile.id}"]})
    |> render_click()

    view
    |> form("#quality-profile-form", %{
      "quality_profile" => %{
        "name" => profile.name,
        "quality_standards" => %{"preferred_resolutions" => ["1080p"]}
      },
      "custom_formats" => %{"lang-vff" => %{"score" => "0", "reject" => "false"}}
    })
    |> render_submit()

    assert CustomFormats.list_assignments(profile) == []
  end

  test "reports an error when custom format scores are invalid", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/quality")

    view
    |> element(~s{button[phx-click="edit_quality_profile"][phx-value-id="#{profile.id}"]})
    |> render_click()

    html =
      view
      |> form("#quality-profile-form", %{
        "quality_profile" => %{
          "name" => profile.name,
          "quality_standards" => %{"preferred_resolutions" => ["1080p"]}
        },
        "custom_formats" => %{
          "lang-vff" => %{"score" => "99999", "reject" => "false"}
        }
      })
      |> render_submit()

    assert html =~ "custom format settings could not be saved"
    assert html =~ "score"
    refute html =~ "Quality profile saved successfully"
  end
end
