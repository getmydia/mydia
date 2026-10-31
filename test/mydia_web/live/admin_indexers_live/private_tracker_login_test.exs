defmodule MydiaWeb.AdminIndexersLive.PrivateTrackerLoginTest do
  @moduledoc """
  The challenge round trip from the Indexers page against the invented
  captcha and 2FA tracker: a search parks it in needs_login, a person answers
  the captcha and the one-time code, and searches resume on the stored session.
  """
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts
  alias Mydia.Indexers
  alias Mydia.Indexers.Adapter.Cardigann, as: Adapter
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.{CardigannAuth, CardigannDefinition}
  alias Mydia.PrivateTrackerFixtures, as: Trackers
  alias Mydia.Repo

  @secrets Trackers.secrets()

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    start_supervised!(Mydia.Indexers.Health)
    Mydia.Indexers.register_adapters()

    original_features = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, cardigann_enabled: true)
    on_exit(fn -> Application.put_env(:mydia, :features, original_features) end)

    tracker =
      Trackers.start_tracker(Bypass.open(), :captcha, %{
        "username" => @secrets.username,
        "password" => @secrets.password
      })

    {:ok, conn: conn, tracker: tracker}
  end

  defp search(definition_id) do
    definition = Repo.get!(CardigannDefinition, definition_id)
    Adapter.search(Indexers.cardigann_config(definition), "Fictional", [])
  end

  test "captcha and 2FA answered on the Indexers page restore searching", %{
    conn: conn,
    tracker: %{definition: d}
  } do
    assert {:error, %Error{type: :login_required}} = search(d.id)
    assert Repo.get!(CardigannDefinition, d.id).health_status == "needs_login"

    {:ok, view, _} = live(conn, ~p"/admin/indexers")
    view |> element("#indexer-login-#{d.id}") |> render_click()
    render_async(view)

    assert has_element?(
             view,
             "#indexer-login-captcha[src='data:image/png;base64,#{Base.encode64(Trackers.captcha_png())}']"
           )

    assert has_element?(view, "#indexer-login-field-2facode")

    view
    |> form("#indexer-login-form", login: %{captcha: @secrets.captcha, "2facode": @secrets.twofa})
    |> render_submit()

    render_async(view)

    refute has_element?(view, "#indexer-login-modal")

    # The answers went to the separate submitpath, in the session the captcha came from.
    assert_received {:tracker, :login, params}
    assert params["imagestring"] == @secrets.captcha
    assert params["two_step_code"] == @secrets.twofa
    assert params["cookie"] =~ "PHPSESSID=har-landing"

    assert Repo.get!(CardigannDefinition, d.id).health_status == "healthy"
    assert {:ok, %{cookies: cookies}} = CardigannAuth.get_stored_session(d.id)
    assert Enum.any?(cookies, &String.starts_with?(&1, "c_secure_uid="))

    assert {:ok, [result]} = search(d.id)
    assert result.title == "Fictional.Salt.Meadow.S02E04.1080p.WEB-DL-INVENTED"
  end

  test "a wrong code keeps the modal open with the tracker's error", %{
    conn: conn,
    tracker: %{definition: d}
  } do
    search(d.id)

    {:ok, view, _} = live(conn, ~p"/admin/indexers")
    view |> element("#indexer-login-#{d.id}") |> render_click()
    render_async(view)

    view
    |> form("#indexer-login-form", login: %{captcha: @secrets.captcha, "2facode": "000000"})
    |> render_submit()

    render_async(view)

    assert has_element?(view, "#indexer-login-modal .alert-error")
    assert has_element?(view, "#indexer-login-captcha")
    assert Repo.get!(CardigannDefinition, d.id).health_status == "needs_login"
  end
end
