defmodule MydiaWeb.AdminSettingsLive.ProxyTest do
  # The proxy config is global (persistent_term) and these tests rewrite the
  # cached runtime config and the relay URL, so they cannot run async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Config.Schema.Proxy, as: ProxyConfig
  alias Mydia.Net.Proxy
  alias Mydia.Settings
  alias Mydia.Test.ConnectProxy
  alias MydiaWeb.AdminSettingsLive.ProxyComponents
  alias MydiaWeb.AdminSettingsLive.ProxySettings

  defp getenv(env), do: fn name -> Map.get(env, name) end

  defp use_proxy(url, env \\ %{}) do
    {:ok, config} = Proxy.effective(%ProxyConfig{url: url}, getenv(env))
    Proxy.put_config(config)
    config
  end

  defp use_standard_fallback(url) do
    {:ok, config} = Proxy.effective(nil, getenv(%{"HTTP_PROXY" => url}))
    Proxy.put_config(config)
    config
  end

  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  setup %{conn: conn} do
    previous_proxy = Proxy.current()
    runtime = Application.get_env(:mydia, :runtime_config)
    relay = Application.get_env(:mydia, :metadata_relay_url)

    on_exit(fn ->
      Proxy.put_config(previous_proxy)

      if runtime,
        do: Application.put_env(:mydia, :runtime_config, runtime),
        else: Application.delete_env(:mydia, :runtime_config)

      if relay,
        do: Application.put_env(:mydia, :metadata_relay_url, relay),
        else: Application.delete_env(:mydia, :metadata_relay_url)
    end)

    Proxy.put_config(nil)
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  describe "proxy row" do
    test "masks the password everywhere it shows the URL", %{conn: conn} do
      use_proxy("http://u:secret@p:1")
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert text(view, "#proxy-url-value") =~ "http://u:****@p:1"
      refute render(view) =~ "secret"

      view |> element("#proxy-edit") |> render_click()
      assert has_element?(view, "#proxy-modal #proxy-form")
      refute render(view) =~ "secret"
    end

    test "labels a standard-variable fallback", %{conn: conn} do
      use_standard_fallback("http://fallback.test:3128")
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert text(view, "#proxy-source") =~ "HTTP_PROXY env"
    end
  end

  describe "editing" do
    test "saving writes the DB overlay and outranks the standard fallback", %{conn: conn} do
      use_standard_fallback("http://fallback.test:3128")
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      view |> element("#proxy-edit") |> render_click()

      view
      |> form("#proxy-form", proxy: %{url: "http://p:3128"})
      |> render_submit()

      setting = Settings.get_config_setting_by_key("proxy.url")
      assert setting.value == "http://p:3128"
      assert setting.category == :proxy
      assert Proxy.current().endpoint == "p:3128"

      refute has_element?(view, "#proxy-modal")
      assert text(view, "#proxy-source") =~ "DB"
    end

    test "rejects a SOCKS URL with the schema's message and writes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      view |> element("#proxy-edit") |> render_click()

      view
      |> form("#proxy-form", proxy: %{url: "socks5://p:1"})
      |> render_submit()

      assert text(view, "#proxy-form") =~ "must be an http:// or https:// proxy URL with a host"
      assert Settings.get_config_setting_by_key("proxy.url") == nil
    end

    test "keeps the stored password when the masked URL is saved with a new host" do
      user = admin_user_fixture()

      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "proxy.url",
          value: "http://u:secret@old.test:1",
          category: :proxy
        })

      {:ok, _} = Mydia.Config.Loader.reload()

      assert {:ok, ["proxy.url"]} =
               ProxySettings.save(%{"url" => "http://u:****@new.test:2"}, user.id, getenv(%{}))

      assert Settings.get_config_setting_by_key("proxy.url").value ==
               "http://u:secret@new.test:2"
    end

    test "an unchanged masked URL writes nothing", %{conn: conn} do
      use_proxy("http://u:secret@p:1")
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      view |> element("#proxy-edit") |> render_click()
      view |> form("#proxy-form") |> render_submit()

      assert Settings.get_config_setting_by_key("proxy.url") == nil
      assert Settings.get_config_setting_by_key("proxy.bypass") == nil
    end

    test "a MYDIA_PROXY_URL value is reported as env and renders read-only" do
      settings = ProxySettings.current(getenv(%{"MYDIA_PROXY_URL" => "http://env.test:1"}))
      assert settings.url_source == :env

      html =
        render_component(&ProxyComponents.proxy_modal/1,
          form: Phoenix.Component.to_form(ProxySettings.changeset(%{}), as: :proxy),
          settings: settings
        )

      doc = LazyHTML.from_fragment(html)
      assert LazyHTML.query(doc, "#proxy-form input[name='proxy[url]'][disabled]") |> Enum.any?()

      refute LazyHTML.query(doc, "#proxy-form input[name='proxy[bypass]'][disabled]")
             |> Enum.any?()
    end
  end

  describe "fallback and masked-password edits" do
    defp store_url(url) do
      {:ok, _} =
        Settings.upsert_config_setting(%{key: "proxy.url", value: url, category: :proxy})

      {:ok, _} = Mydia.Config.Loader.reload()
    end

    defp edit_and_submit(view, url) do
      view |> element("#proxy-edit") |> render_click()
      view |> form("#proxy-form", proxy: %{url: url}) |> render_submit()
    end

    test "a cleared URL that falls back to HTTP_PROXY reads HTTP_PROXY env, not DB", %{
      conn: conn
    } do
      use_standard_fallback("http://fallback.test:3128")
      {:ok, view, _html} = live(conn, ~p"/admin/settings")
      edit_and_submit(view, "")

      assert Settings.get_config_setting_by_key("proxy.url").value in ["", nil]

      # The reload above resolved against the real environment; put the
      # injected fallback back, as it would be when HTTP_PROXY is set.
      use_standard_fallback("http://fallback.test:3128")
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert text(view, "#proxy-source") =~ "HTTP_PROXY env"
      refute text(view, "#proxy-source") =~ "DB"
    end

    test "a new user name with the masked password is refused", %{conn: conn} do
      store_url("http://u:secret@old.test:1")
      {:ok, view, _html} = live(conn, ~p"/admin/settings")
      edit_and_submit(view, "http://v:****@old.test:1")

      assert text(view, "#proxy-form") =~ "enter the password for the new user"
      assert Settings.get_config_setting_by_key("proxy.url").value == "http://u:secret@old.test:1"
      refute render(view) =~ "secret"
    end

    test "save/3 refuses a mask it cannot restore" do
      store_url("http://u:secret@old.test:1")

      assert {:error, %Ecto.Changeset{} = changeset} =
               ProxySettings.save(%{"url" => "http://v:****@old.test:1"}, nil, getenv(%{}))

      assert {"enter the password for the new user", _} = changeset.errors[:url]
    end

    test "a password-less URL round-trips through the modal", %{conn: conn} do
      store_url("http://u@old.test:1")
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert text(view, "#proxy-url-value") =~ "http://u@old.test:1"
      refute render(view) =~ "****"

      edit_and_submit(view, "http://u@new.test:2")
      assert Settings.get_config_setting_by_key("proxy.url").value == "http://u@new.test:2"
    end

    test "a mask over a password-less stored URL is refused, not saved as the password" do
      store_url("http://u@old.test:1")

      assert {:error, %Ecto.Changeset{}} =
               ProxySettings.save(%{"url" => "http://u:****@new.test:2"}, nil, getenv(%{}))

      assert Settings.get_config_setting_by_key("proxy.url").value == "http://u@old.test:1"
    end
  end

  describe "Test proxy" do
    test "is disabled when no proxy is configured", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")
      assert has_element?(view, "#proxy-test[disabled]")
    end

    test "reports the relay's status through the proxy", %{conn: conn} do
      bypass = Bypass.open()
      Bypass.expect_once(bypass, "GET", "/health", &Plug.Conn.resp(&1, 200, "ok"))
      {:ok, proxy} = ConnectProxy.start(respond: :forward)
      use_proxy("http://127.0.0.1:#{proxy.port}")

      Application.put_env(
        :mydia,
        :metadata_relay_url,
        "http://tracker.example.test:#{bypass.port}"
      )

      {:ok, view, _html} = live(conn, ~p"/admin/settings")
      view |> element("#proxy-test") |> render_click()
      render_async(view)

      assert text(view, "#proxy-test-result") =~ "200"
    end

    test "reports a proxy that wants credentials", %{conn: conn} do
      {:ok, proxy} = ConnectProxy.start(respond: {:status, 407})
      use_proxy("http://127.0.0.1:#{proxy.port}")
      Application.put_env(:mydia, :metadata_relay_url, "https://tracker.example.test")

      {:ok, view, _html} = live(conn, ~p"/admin/settings")
      view |> element("#proxy-test") |> render_click()
      render_async(view)

      assert text(view, "#proxy-test-result") =~ "requires authentication"
    end
  end
end
