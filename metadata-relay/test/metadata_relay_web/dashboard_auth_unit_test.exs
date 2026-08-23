defmodule MetadataRelayWeb.DashboardAuthUnitTest do
  use ExUnit.Case, async: false

  import MetadataRelay.Test.GitHubHelpers

  alias MetadataRelayWeb.DashboardAuth

  setup do
    previous = put_dashboard_org(nil)

    on_exit(fn ->
      restore_dashboard_org(previous)
      clear_github_adapter()
    end)

    :ok
  end

  test "mode is basic when no organization is configured" do
    put_dashboard_org(nil)
    assert DashboardAuth.mode() == :basic

    put_dashboard_org("")
    assert DashboardAuth.mode() == :basic

    put_dashboard_org("   ")
    assert DashboardAuth.mode() == :basic
  end

  test "mode is github once an organization is configured" do
    put_dashboard_org("getmydia")
    assert DashboardAuth.mode() == :github
    assert DashboardAuth.org() == "getmydia"
  end

  test "verify_membership accepts only an active membership" do
    put_dashboard_org("getmydia")

    stub_membership(Req.Response.new(status: 200, body: active_membership()))
    assert DashboardAuth.verify_membership("gho_token") == :ok

    stub_membership(Req.Response.new(status: 200, body: %{"state" => "pending"}))
    assert DashboardAuth.verify_membership("gho_token") == {:error, :denied}

    stub_membership(Req.Response.new(status: 404, body: %{}))
    assert DashboardAuth.verify_membership("gho_token") == {:error, :denied}
  end

  test "verify_membership separates a refusal from an outage" do
    put_dashboard_org("getmydia")

    stub_membership(Req.Response.new(status: 403, body: %{}))
    assert DashboardAuth.verify_membership("gho_token") == {:error, :denied}

    stub_membership(Req.Response.new(status: 500, body: %{}))
    assert DashboardAuth.verify_membership("gho_token") == {:error, :unavailable}

    set_github_adapter(fn request -> {request, %Req.TransportError{reason: :econnrefused}} end)
    assert DashboardAuth.verify_membership("gho_token") == {:error, :unavailable}
  end

  test "a rate-limited 403 does not end a session the way a refusal does" do
    put_dashboard_org("getmydia")

    stub_membership(Req.Response.new(status: 403, body: %{}, headers: %{"retry-after" => ["60"]}))

    assert DashboardAuth.verify_membership("gho_token") == {:error, :unavailable}
  end

  test "verify_membership refuses without an organization or a token" do
    put_dashboard_org(nil)
    assert DashboardAuth.verify_membership("gho_token") == {:error, :denied}

    put_dashboard_org("getmydia")
    assert DashboardAuth.verify_membership(nil) == {:error, :denied}
  end

  test "verification_fresh? tracks the revalidation window" do
    assert DashboardAuth.verification_fresh?(DashboardAuth.verified_now())
    refute DashboardAuth.verification_fresh?(DashboardAuth.verified_now() - 100_000)
    refute DashboardAuth.verification_fresh?(nil)
    refute DashboardAuth.verification_fresh?("not a timestamp")
  end

  test "safe_return_to keeps local paths and rejects everything else" do
    assert DashboardAuth.safe_return_to("/feedback?focus=abc") == "/feedback?focus=abc"
    assert DashboardAuth.safe_return_to("/errors") == "/errors"

    assert DashboardAuth.safe_return_to("//evil.example.com") == "/feedback"
    assert DashboardAuth.safe_return_to("https://evil.example.com") == "/feedback"
    assert DashboardAuth.safe_return_to("/\\evil.example.com") == "/feedback"
    assert DashboardAuth.safe_return_to("feedback") == "/feedback"
    assert DashboardAuth.safe_return_to(nil) == "/feedback"
  end

  describe "on_mount/4" do
    test "basic mode mounts with no GitHub identity" do
      put_dashboard_org(nil)

      assert {:cont, socket} = mount_with(%{})
      assert socket.assigns.github_login == nil
      assert socket.assigns.github_token == nil
    end

    test "a fresh session mounts without calling GitHub" do
      put_dashboard_org("getmydia")
      set_github_adapter(fn _request -> raise "GitHub must not be called for a fresh session" end)

      assert {:cont, socket} = mount_with(session())
      assert socket.assigns.github_login == "arsfeld"
      assert socket.assigns.github_token == "gho_token"
    end

    test "a session without a login or token is turned away" do
      put_dashboard_org("getmydia")

      assert {:halt, _} = mount_with(%{})
      assert {:halt, _} = mount_with(session(login: nil))
      assert {:halt, _} = mount_with(session(login: ""))
      assert {:halt, _} = mount_with(session(token: nil))
    end

    test "a stale session is turned away once GitHub refuses" do
      put_dashboard_org("getmydia")
      stub_membership(Req.Response.new(status: 404, body: %{}))

      assert {:halt, _} = mount_with(session(verified_at: stale()))
    end

    test "a stale session survives an unreachable GitHub" do
      put_dashboard_org("getmydia")
      stub_membership(Req.Response.new(status: 500, body: %{}))

      assert {:cont, socket} = mount_with(session(verified_at: stale()))
      assert socket.assigns.github_login == "arsfeld"
    end

    defp mount_with(session) do
      DashboardAuth.on_mount(
        :require_github_login,
        %{},
        session,
        %Phoenix.LiveView.Socket{}
      )
    end

    defp session(opts \\ []) do
      %{
        "github_login" => Keyword.get(opts, :login, "arsfeld"),
        "github_token" => Keyword.get(opts, :token, "gho_token"),
        "github_verified_at" => Keyword.get(opts, :verified_at, DashboardAuth.verified_now())
      }
    end

    defp stale, do: DashboardAuth.verified_now() - 100_000
  end

  defp stub_membership(response) do
    set_github_adapter(fn request -> {request, response} end)
  end
end
