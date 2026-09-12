defmodule MydiaWeb.Plugs.LibraryApiAuthTest do
  use MydiaWeb.ConnCase

  alias Mydia.Accounts
  alias Mydia.AccountsFixtures
  alias Mydia.Accounts.ApiKeyRateLimiter
  alias Mydia.Auth.Guardian
  alias Mydia.LibraryApi.Principal
  alias MydiaWeb.Plugs.LibraryApiAuth

  @ip "127.0.0.1"
  @bucket "library_api:#{@ip}"

  setup do
    ApiKeyRateLimiter.reset_rate_limit(@bucket)

    # Both the OS variable and the application env are restored, because the
    # environment-key tests set both. Restoring only the OS variable would leave
    # `Application.put_env(:mydia, :library_api_key, ...)` in place for every later
    # test in this module, letting them authenticate against leaked state.
    previous_env = System.get_env("LIBRARY_API_KEY")
    previous_config = Application.get_env(:mydia, :library_api_key)

    on_exit(fn ->
      case previous_env do
        nil -> System.delete_env("LIBRARY_API_KEY")
        value -> System.put_env("LIBRARY_API_KEY", value)
      end

      case previous_config do
        nil -> Application.delete_env(:mydia, :library_api_key)
        value -> Application.put_env(:mydia, :library_api_key, value)
      end
    end)

    :ok
  end

  defp call(conn), do: LibraryApiAuth.call(conn, [])

  defp admin_key do
    user = AccountsFixtures.admin_user_fixture()

    {:ok, _record, plain} =
      Accounts.create_api_key(user.id, %{name: "Lib", permissions: ["admin"]})

    plain
  end

  describe "database keys" do
    test "authenticates an admin-scoped key" do
      conn = build_conn() |> put_req_header("x-api-key", admin_key()) |> call()

      refute conn.halted
      assert %Principal{role: "admin", source: :api_key} = conn.assigns[:library_api_principal]
    end

    test "rejects a missing key with 401" do
      conn = call(build_conn())
      assert conn.halted
      assert conn.status == 401
    end

    test "rejects an invalid key with 401 and records the failure" do
      conn = build_conn() |> put_req_header("x-api-key", "nope") |> call()
      assert conn.halted
      assert conn.status == 401
    end

    test "rejects a key without the admin permission with 403" do
      user = AccountsFixtures.admin_user_fixture()

      {:ok, _record, plain} =
        Accounts.create_api_key(user.id, %{name: "Read only", permissions: ["read"]})

      conn = build_conn() |> put_req_header("x-api-key", plain) |> call()
      assert conn.halted
      assert conn.status == 403
    end

    test "rejects an admin-scoped key owned by a non-admin user with 403" do
      user = AccountsFixtures.user_fixture()

      {:ok, _record, plain} =
        Accounts.create_api_key(user.id, %{name: "Sneaky", permissions: ["admin"]})

      conn = build_conn() |> put_req_header("x-api-key", plain) |> call()
      assert conn.halted
      assert conn.status == 403
    end

    test "rejects a revoked key with 401" do
      user = AccountsFixtures.admin_user_fixture()

      {:ok, record, plain} =
        Accounts.create_api_key(user.id, %{name: "Gone", permissions: ["admin"]})

      {:ok, _} = Accounts.revoke_api_key(record)

      conn = build_conn() |> put_req_header("x-api-key", plain) |> call()
      assert conn.status == 401
    end

    test "rejects an expired key with 401" do
      user = AccountsFixtures.admin_user_fixture()

      {:ok, _record, plain} =
        Accounts.create_api_key(user.id, %{
          name: "Old",
          permissions: ["admin"],
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      conn = build_conn() |> put_req_header("x-api-key", plain) |> call()
      assert conn.status == 401
    end

    test "rate limits repeated failures with 429" do
      ApiKeyRateLimiter.reset_rate_limit(@bucket)

      for _ <- 1..10 do
        build_conn() |> put_req_header("x-api-key", "nope") |> call()
      end

      conn = build_conn() |> put_req_header("x-api-key", "nope") |> call()
      assert conn.halted
      assert conn.status == 429
    end
  end

  describe "other credential types" do
    test "rejects a Guardian session/bearer token with 401" do
      user = AccountsFixtures.admin_user_fixture()
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> call()

      assert conn.status == 401
    end

    test "ignores the api_key query parameter" do
      conn =
        build_conn(:get, "/?api_key=#{admin_key()}") |> Plug.Conn.fetch_query_params() |> call()

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "the environment key" do
    test "authenticates and needs no database row" do
      secret = String.duplicate("e", 40)
      System.put_env("LIBRARY_API_KEY", secret)
      Application.put_env(:mydia, :library_api_key, secret)

      conn = build_conn() |> put_req_header("x-api-key", secret) |> call()

      refute conn.halted

      assert %Principal{role: "admin", source: :env, user: nil} =
               conn.assigns[:library_api_principal]
    end

    test "is ignored when the configured value does not match" do
      System.put_env("LIBRARY_API_KEY", String.duplicate("e", 40))
      Application.put_env(:mydia, :library_api_key, String.duplicate("e", 40))

      conn = build_conn() |> put_req_header("x-api-key", String.duplicate("f", 40)) |> call()
      assert conn.status == 401
    end
  end
end
