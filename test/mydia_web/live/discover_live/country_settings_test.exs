defmodule MydiaWeb.DiscoverLive.CountrySettingsTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference
  alias Mydia.Metadata.Cache

  @maple %{"id" => 8001, "name" => "Maplestream"}

  setup %{conn: conn} do
    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Cache.clear()

      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    warm_genre_cache(:movie, [])
    warm_genre_cache(:tv_show, [])
    warm_trending_cache(:movie, [])
    stub_discover(bypass)

    user = create_admin_user()
    %{conn: log_in_user(conn, user), user: user, bypass: bypass}
  end

  defp stub_discover(bypass) do
    for path <- ["/tmdb/movies/discover", "/tmdb/tv/discover"] do
      Bypass.stub(bypass, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"page" => 1, "total_pages" => 1, "results" => []}))
      end)
    end
  end

  # CA offers Maplestream and Northflix; FR offers only Northflix.
  defp stub_providers(bypass, status \\ 200) do
    for type <- ["movie", "tv"] do
      Bypass.stub(bypass, "GET", "/tmdb/watch/providers/#{type}", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        results =
          case conn.query_params["watch_region"] do
            "FR" ->
              [%{"provider_id" => 8002, "provider_name" => "Northflix", "display_priority" => 1}]

            _ ->
              [
                %{
                  "provider_id" => 8001,
                  "provider_name" => "Maplestream",
                  "display_priority" => 1
                },
                %{"provider_id" => 8002, "provider_name" => "Northflix", "display_priority" => 2}
              ]
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, Jason.encode!(%{"results" => results}))
      end)
    end
  end

  defp save_prefs(user, country, services) do
    {:ok, _} =
      Accounts.update_preference(Accounts.get_user_preference!(user), %{
        "preferences" => %{
          "discover_home_country" => country,
          "discover_streaming_services" => services
        }
      })
  end

  defp pref(user), do: Accounts.get_user_preference!(user)

  defp open(view) do
    view |> element("#discover-country-settings-button") |> render_click()
    render_async(view, 5_000)
  end

  describe "header" do
    test "no country: one '+ Your country' button and none of the old controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-country-settings-button", "Your country")
      refute has_element?(view, "#discover-home-tab")

      for old <- [
            "#discover-home-country-add",
            "#discover-home-country-menu",
            "#discover-home-country-picker",
            "#discover-services-button"
          ] do
        refute has_element?(view, old)
      end
    end

    test "country set: the tab and the same button", %{conn: conn, user: user} do
      save_prefs(user, "CA", [@maple])

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")

      assert has_element?(view, "#discover-home-tab", "Canada")
      assert has_element?(view, "#discover-country-settings-button", "Your country")
      refute has_element?(view, "#discover-home-country-menu")
      refute has_element?(view, "#discover-services-button")
    end
  end

  describe "modal" do
    test "opens with the saved country and ticked services", %{
      conn: conn,
      user: user,
      bypass: bypass
    } do
      stub_providers(bypass)
      save_prefs(user, "CA", [@maple])

      {:ok, view, _html} = live(conn, ~p"/discover")
      open(view)

      assert has_element?(
               view,
               "#discover-country-settings select[name='country'] option[value='CA'][selected]"
             )

      assert has_element?(
               view,
               "#discover-country-settings-services input[value='8001'][checked]"
             )

      assert has_element?(
               view,
               "#discover-country-settings-services input[value='8002']:not([checked])"
             )

      assert has_element?(view, "#discover-country-settings-remove")
    end

    test "no country: services hidden, save disabled, no remove", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discover")
      open(view)

      assert has_element?(
               view,
               "#discover-country-settings option[value=''][selected]",
               "Pick a country"
             )

      refute has_element?(view, "#discover-country-settings-services")
      assert has_element?(view, "#discover-country-settings-save[disabled]")
      refute has_element?(view, "#discover-country-settings-remove")
    end

    test "picking a country loads its services", %{conn: conn, bypass: bypass} do
      stub_providers(bypass)
      {:ok, view, _html} = live(conn, ~p"/discover")
      open(view)

      view |> element("#discover-country-settings-form") |> render_change(%{"country" => "CA"})
      render_async(view, 5_000)

      assert has_element?(view, "#discover-country-settings-services input[value='8001']")
      assert has_element?(view, "#discover-country-settings-services input[value='8002']")
    end

    test "changing country drops ticks the new country does not offer", %{
      conn: conn,
      user: user,
      bypass: bypass
    } do
      stub_providers(bypass)
      save_prefs(user, "CA", [@maple, %{"id" => 8002, "name" => "Northflix"}])

      {:ok, view, _html} = live(conn, ~p"/discover")
      open(view)

      view
      |> element("#discover-country-settings-form")
      |> render_change(%{"country" => "FR", "services" => ["8001", "8002"]})

      render_async(view, 5_000)

      refute has_element?(view, "#discover-country-settings-services input[value='8001']")

      assert has_element?(
               view,
               "#discover-country-settings-services input[value='8002'][checked]"
             )
    end

    test "save writes both and opens the tab", %{conn: conn, user: user, bypass: bypass} do
      stub_providers(bypass)
      {:ok, view, _html} = live(conn, ~p"/discover")
      open(view)

      view |> element("#discover-country-settings-form") |> render_change(%{"country" => "CA"})
      render_async(view, 5_000)

      view
      |> form("#discover-country-settings-form", %{"country" => "CA", "services" => ["8002"]})
      |> render_submit()

      assert_patch(view, ~p"/discover?#{%{"category" => "home", "type" => "movie"}}")
      refute has_element?(view, "#discover-country-settings")
      assert has_element?(view, "#discover-home-tab.tab-active", "Canada")
      assert UserPreference.discover_home_country(pref(user)) == "CA"

      assert UserPreference.discover_streaming_services(pref(user)) == [
               %{"id" => 8002, "name" => "Northflix"}
             ]
    end

    test "a forged service id is dropped on save", %{conn: conn, user: user, bypass: bypass} do
      stub_providers(bypass)
      save_prefs(user, "CA", [])

      {:ok, view, _html} = live(conn, ~p"/discover")
      open(view)

      render_submit(view, "save_country_settings", %{
        "country" => "CA",
        "services" => ["8001", "999999"]
      })

      assert UserPreference.discover_streaming_services(pref(user)) == [@maple]
    end

    test "a forged country is not saved and the modal stays open", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/discover")
      open(view)

      render_submit(view, "save_country_settings", %{"country" => "XX"})

      assert UserPreference.discover_home_country(pref(user)) == nil
      assert has_element?(view, "#discover-country-settings")
    end

    test "a failed provider list offers a retry and still saves the country", %{
      conn: conn,
      user: user,
      bypass: bypass
    } do
      stub_providers(bypass, 500)
      {:ok, view, _html} = live(conn, ~p"/discover")
      open(view)

      view |> element("#discover-country-settings-form") |> render_change(%{"country" => "CA"})
      render_async(view, 20_000)

      assert has_element?(view, "#discover-country-settings-retry")

      view
      |> form("#discover-country-settings-form", %{"country" => "CA"})
      |> render_submit()

      assert UserPreference.discover_home_country(pref(user)) == "CA"
      assert UserPreference.discover_streaming_services(pref(user)) == []
    end

    test "unchanged country with a failed provider list keeps the saved services", %{
      conn: conn,
      user: user,
      bypass: bypass
    } do
      stub_providers(bypass, 500)
      save_prefs(user, "CA", [@maple])

      {:ok, view, _html} = live(conn, ~p"/discover")
      view |> element("#discover-country-settings-button") |> render_click()
      render_async(view, 20_000)

      view
      |> form("#discover-country-settings-form", %{"country" => "CA"})
      |> render_submit()

      assert UserPreference.discover_streaming_services(pref(user)) == [@maple]
    end

    test "cancel discards", %{conn: conn, user: user, bypass: bypass} do
      stub_providers(bypass)
      {:ok, view, _html} = live(conn, ~p"/discover")
      open(view)

      view |> element("#discover-country-settings-form") |> render_change(%{"country" => "CA"})
      view |> element("#discover-country-settings-cancel") |> render_click()

      refute has_element?(view, "#discover-country-settings")
      assert UserPreference.discover_home_country(pref(user)) == nil
    end

    test "remove clears both and leaves the tab", %{conn: conn, user: user, bypass: bypass} do
      stub_providers(bypass)
      save_prefs(user, "CA", [@maple])

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")
      open(view)

      view |> element("#discover-country-settings-remove") |> render_click()

      assert_patch(view, ~p"/discover?#{%{"type" => "movie"}}")
      refute has_element?(view, "#discover-home-tab")
      assert UserPreference.discover_home_country(pref(user)) == nil
      assert pref(user).preferences["discover_streaming_services"] == []
    end

    test "the rows' services prompt opens the modal", %{conn: conn, user: user, bypass: bypass} do
      stub_providers(bypass)
      save_prefs(user, "CA", [])

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&category=home")
      render_async(view, 5_000)

      view |> element("#discover-services-prompt-open") |> render_click()
      assert has_element?(view, "#discover-country-settings")
    end
  end
end
