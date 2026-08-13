defmodule MetadataRelay.SubDL.ConfigurationTest do
  @moduledoc """
  A relay with no SubDL key answers every subtitle search with a 503 and is
  otherwise indistinguishable from a healthy one. That is how the outage this
  backend replaced went unnoticed for months, so the missing key has to be
  visible at boot and over `/health`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MetadataRelay.Router
  alias MetadataRelay.SubDL.Client

  @opts Router.init([])

  setup do
    original = System.get_env("SUBDL_API_KEY")

    on_exit(fn ->
      if original,
        do: System.put_env("SUBDL_API_KEY", original),
        else: System.delete_env("SUBDL_API_KEY")
    end)

    :ok
  end

  defp health do
    Plug.Test.conn(:get, "/health")
    |> Router.call(@opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  describe "Client.configured?/0" do
    test "is false when the key is missing or blank" do
      System.delete_env("SUBDL_API_KEY")
      refute Client.configured?()

      System.put_env("SUBDL_API_KEY", "")
      refute Client.configured?()
    end

    test "is true when the key is set" do
      System.put_env("SUBDL_API_KEY", "test_key")
      assert Client.configured?()
    end
  end

  describe "GET /health" do
    test "reports subtitle support as configured when the key is set" do
      System.put_env("SUBDL_API_KEY", "test_key")

      body = health()

      assert body["subtitles_configured"] == true
      # The existing fields are part of the deployed contract.
      assert body["status"] == "ok"
      assert body["service"] == "metadata-relay"
      assert body["version"] == MetadataRelay.version()
    end

    test "reports subtitle support as unconfigured when the key is missing" do
      System.delete_env("SUBDL_API_KEY")

      body = health()

      assert body["subtitles_configured"] == false
      assert body["status"] == "ok"
    end
  end

  describe "boot logging" do
    test "warns when the key is missing" do
      System.delete_env("SUBDL_API_KEY")

      log = capture_log(fn -> MetadataRelay.Application.log_subtitle_support() end)

      assert log =~ "SUBDL_API_KEY"
      assert log =~ "subtitle support disabled"
      assert log =~ "[warning]"
    end

    test "warns when the key is blank" do
      System.put_env("SUBDL_API_KEY", "   ")

      log = capture_log(fn -> MetadataRelay.Application.log_subtitle_support() end)

      assert log =~ "subtitle support disabled"
      assert log =~ "[warning]"
    end

    test "confirms the key at info level when it is set" do
      System.put_env("SUBDL_API_KEY", "test_key")

      # The test env pins the logger to :warning, so info never reaches the
      # capture handler unless this module is lowered for the duration.
      Logger.put_module_level(MetadataRelay.Application, :info)
      on_exit(fn -> Logger.delete_module_level(MetadataRelay.Application) end)

      log =
        capture_log([level: :info], fn -> MetadataRelay.Application.log_subtitle_support() end)

      assert log =~ "subtitle support enabled"
      refute log =~ "test_key"
    end
  end
end
