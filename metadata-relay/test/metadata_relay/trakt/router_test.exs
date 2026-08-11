defmodule MetadataRelay.Trakt.RouterTest do
  @moduledoc """
  Covers the relay's behaviour when Trakt credentials are absent.

  This is the production failure this suite was written for: the live relay
  carried no TRAKT_CLIENT_ID, `Client.client_id/0` raised, and the raise
  escaped as a generic HTML 500. Mydia could not tell that apart from an
  outage and told users to "try again", which could never succeed.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias MetadataRelay.Router
  alias MetadataRelay.Trakt.Client

  setup do
    previous = %{
      id: Application.get_env(:metadata_relay, :trakt_client_id),
      secret: Application.get_env(:metadata_relay, :trakt_client_secret),
      env_id: System.get_env("TRAKT_CLIENT_ID"),
      env_secret: System.get_env("TRAKT_CLIENT_SECRET")
    }

    # The lookup falls back to the OS environment, so a developer with real
    # credentials exported would otherwise see these tests pass for the wrong
    # reason. async: false, and everything is put back in on_exit.
    System.delete_env("TRAKT_CLIENT_ID")
    System.delete_env("TRAKT_CLIENT_SECRET")

    on_exit(fn ->
      restore(:trakt_client_id, previous.id)
      restore(:trakt_client_secret, previous.secret)
      restore_env("TRAKT_CLIENT_ID", previous.env_id)
      restore_env("TRAKT_CLIENT_SECRET", previous.env_secret)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:metadata_relay, key)
  defp restore(key, value), do: Application.put_env(:metadata_relay, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp unconfigure do
    Application.put_env(:metadata_relay, :trakt_client_id, nil)
    Application.put_env(:metadata_relay, :trakt_client_secret, nil)
  end

  defp post_json(path, body) do
    :post
    |> Plug.Test.conn(path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Router.call([])
  end

  describe "Client.configured?/0" do
    test "is false when both credentials are missing" do
      unconfigure()
      refute Client.configured?()
    end

    test "is false when only the client id is set" do
      unconfigure()
      Application.put_env(:metadata_relay, :trakt_client_id, "some-id")
      refute Client.configured?()
    end

    test "is false when a credential is set but blank" do
      Application.put_env(:metadata_relay, :trakt_client_id, "   ")
      Application.put_env(:metadata_relay, :trakt_client_secret, "some-secret")

      refute Client.configured?(),
             "a blank credential must not count as configured, otherwise the relay " <>
               "sends an empty trakt-api-key and Trakt answers 403"
    end

    test "is true when both credentials are present" do
      Application.put_env(:metadata_relay, :trakt_client_id, "some-id")
      Application.put_env(:metadata_relay, :trakt_client_secret, "some-secret")

      assert Client.configured?()
    end
  end

  describe "POST /trakt/oauth/device/code without credentials" do
    setup do
      unconfigure()
      :ok
    end

    test "answers 503 instead of raising into a 500" do
      conn = post_json("/trakt/oauth/device/code", %{})

      assert conn.status == 503
    end

    test "answers JSON, not the generic HTML error page" do
      conn = post_json("/trakt/oauth/device/code", %{})

      assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    end

    test "carries a machine-readable error code the client can match on" do
      conn = post_json("/trakt/oauth/device/code", %{})

      assert %{"error" => "trakt_not_configured", "message" => message} =
               Jason.decode!(conn.resp_body)

      assert message =~ "TRAKT_CLIENT_ID"
    end
  end

  describe "other Trakt endpoints without credentials" do
    setup do
      unconfigure()
      :ok
    end

    test "the device token poll answers 503 rather than a poll status code" do
      conn = post_json("/trakt/oauth/device/token", %{"device_code" => "abc"})

      assert conn.status == 503
      assert %{"error" => "trakt_not_configured"} = Jason.decode!(conn.resp_body)
    end

    test "token refresh answers 503" do
      conn = post_json("/trakt/oauth/refresh", %{"refresh_token" => "abc"})

      assert conn.status == 503
      assert %{"error" => "trakt_not_configured"} = Jason.decode!(conn.resp_body)
    end

    test "token revoke answers 503" do
      conn = post_json("/trakt/oauth/revoke", %{"token" => "abc"})

      assert conn.status == 503
      assert %{"error" => "trakt_not_configured"} = Jason.decode!(conn.resp_body)
    end
  end
end
