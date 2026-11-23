defmodule MydiaWeb.AdminSettingsLiveOidcDefaultRoleTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Settings

  @form "#setting-form-auth-oidc_default_role"

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

  test "offers every non-admin role, with guest selected by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    assert has_element?(view, "#{@form} option[value='guest'][selected]")
    assert has_element?(view, "#{@form} option[value='readonly']")
    assert has_element?(view, "#{@form} option[value='user']")
    refute has_element?(view, "#{@form} option[value='admin']")
  end

  test "choosing a role stores it and applies it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    view
    |> form(@form, %{"settings" => %{"auth.oidc_default_role" => "readonly"}})
    |> render_change(%{"category" => "Authentication"})

    assert Settings.get_config_setting_by_key("auth.oidc_default_role").value == "readonly"
    assert Mydia.Config.get().auth.oidc_default_role == "readonly"
    assert has_element?(view, "#{@form} option[value='readonly'][selected]")
  end
end
