defmodule MydiaWeb.AdminSettingsLiveMinimumAvailabilityTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Settings

  @form "#setting-form-media-minimum_availability"

  setup %{conn: conn} do
    original_config = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_config,
        do: Application.put_env(:mydia, :runtime_config, original_config),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    admin = create_admin_user()
    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(admin)

    %{conn: conn |> init_test_session(%{}) |> put_session(:guardian_default_token, token)}
  end

  test "offers the three levels, with released selected by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    assert has_element?(view, "#{@form} option[value='released'][selected]")
    assert has_element?(view, "#{@form} option[value='in_cinemas']")
    assert has_element?(view, "#{@form} option[value='announced']")
  end

  test "choosing a level stores it and applies it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    view
    |> form(@form, %{"settings" => %{"media.minimum_availability" => "in_cinemas"}})
    |> render_change(%{"category" => "Media"})

    assert Settings.get_config_setting_by_key("media.minimum_availability").value ==
             "in_cinemas"

    assert Mydia.Config.get().media.minimum_availability == "in_cinemas"
    assert has_element?(view, "#{@form} option[value='in_cinemas'][selected]")
  end
end
