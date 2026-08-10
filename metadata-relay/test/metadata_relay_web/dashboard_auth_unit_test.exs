defmodule MetadataRelayWeb.DashboardAuthUnitTest do
  use ExUnit.Case, async: false

  alias MetadataRelayWeb.DashboardAuth

  setup do
    previous = Application.get_env(:metadata_relay, :dashboard_github_users)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:metadata_relay, :dashboard_github_users)
        value -> Application.put_env(:metadata_relay, :dashboard_github_users, value)
      end
    end)

    :ok
  end

  test "mode is basic when no logins are allowlisted" do
    Application.delete_env(:metadata_relay, :dashboard_github_users)
    assert DashboardAuth.mode() == :basic

    Application.put_env(:metadata_relay, :dashboard_github_users, [])
    assert DashboardAuth.mode() == :basic
  end

  test "mode is github once a login is allowlisted" do
    Application.put_env(:metadata_relay, :dashboard_github_users, ["arsfeld"])
    assert DashboardAuth.mode() == :github
  end

  test "allowed? compares logins case-insensitively" do
    Application.put_env(:metadata_relay, :dashboard_github_users, ["ArsFeld"])

    assert DashboardAuth.allowed?("arsfeld")
    assert DashboardAuth.allowed?("ARSFELD")
    refute DashboardAuth.allowed?("someone-else")
    refute DashboardAuth.allowed?(nil)
    refute DashboardAuth.allowed?("")
  end

  test "allowed? is false in basic mode" do
    Application.delete_env(:metadata_relay, :dashboard_github_users)
    refute DashboardAuth.allowed?("arsfeld")
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
end
