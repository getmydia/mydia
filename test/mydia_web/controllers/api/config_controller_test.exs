defmodule MydiaWeb.Api.ConfigControllerTest do
  use MydiaWeb.ConnCase, async: true

  setup do
    {_admin, token} = MydiaWeb.AuthHelpers.create_user_and_token(%{role: "admin"})
    {:ok, token: token}
  end

  describe "PUT /api/v1/config/:key" do
    test "accepts a value with no description", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put("/api/v1/config/media.auto_search_on_add", %{"value" => "false"})

      assert json_response(conn, 200)
    end

    # The row's category is what the admin settings page groups by, and the
    # admin toggle and the migration both file this key under remote_access.
    test "files a new remote_access.enabled row under remote_access", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put("/api/v1/config/remote_access.enabled", %{"value" => "false"})

      assert json_response(conn, 200)

      assert %{value: "false", category: :remote_access} =
               Mydia.Settings.get_config_setting_by_key("remote_access.enabled")
    end
  end

  describe "cardigann.engine" do
    alias Mydia.Indexers.Cardigann.EngineSwitcher
    alias Mydia.Settings.ConfigSetting

    setup %{conn: conn, token: token} do
      runtime = Application.get_env(:mydia, :runtime_config)
      Application.put_env(:mydia, :fake_wasm_engine_pid, self())
      Application.delete_env(:mydia, :fake_wasm_engine_status)
      Mydia.Repo.delete_all(ConfigSetting)
      {:ok, _} = Mydia.Config.Loader.reload()

      # A switcher owned by this test under the default name the controller
      # calls; the application's own (if Cardigann was on at boot) is restored.
      Supervisor.terminate_child(Mydia.Supervisor, EngineSwitcher)
      start_supervised!(EngineSwitcher)

      on_exit(fn ->
        Supervisor.restart_child(Mydia.Supervisor, EngineSwitcher)
        Application.put_env(:mydia, :runtime_config, runtime)
        Application.delete_env(:mydia, :fake_wasm_engine_pid)
        System.delete_env("CARDIGANN_ENGINE")
        :persistent_term.erase({EngineSwitcher, :active})
        Mydia.Indexers.register_adapters()
      end)

      %{conn: put_req_header(conn, "authorization", "Bearer #{token}")}
    end

    test "PUT applies the engine at runtime", %{conn: conn} do
      conn = put(conn, "/api/v1/config/cardigann.engine", %{"value" => "prowlarr"})
      assert json_response(conn, 200)

      assert_receive {:fake_engine, :ensure_started}
      assert %{desired: :prowlarr} = EngineSwitcher.status()
      assert Mydia.Indexers.Cardigann.EngineSetting.setting() == :prowlarr

      assert %{value: "prowlarr", category: :cardigann} =
               Mydia.Settings.get_config_setting_by_key("cardigann.engine")
    end

    test "PUT rejects an unknown engine", %{conn: conn} do
      conn = put(conn, "/api/v1/config/cardigann.engine", %{"value" => "nonsense"})
      assert %{"error" => "Validation failed"} = json_response(conn, 422)
      assert Mydia.Settings.get_config_setting_by_key("cardigann.engine") == nil
    end

    test "PUT is forbidden while CARDIGANN_ENGINE is set", %{conn: conn} do
      System.put_env("CARDIGANN_ENGINE", "builtin")
      conn = put(conn, "/api/v1/config/cardigann.engine", %{"value" => "prowlarr"})
      assert json_response(conn, 403)
    end

    test "DELETE resets the engine to builtin", %{conn: conn} do
      put(conn, "/api/v1/config/cardigann.engine", %{"value" => "prowlarr"})

      conn = delete(conn, "/api/v1/config/cardigann.engine")
      assert json_response(conn, 200)

      assert %{desired: :builtin, active: :builtin} = EngineSwitcher.status()
      assert Mydia.Indexers.Cardigann.EngineSetting.setting() == :builtin
    end
  end
end
