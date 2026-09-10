defmodule MetadataRelay.CrashReportTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias MetadataRelay.Router

  setup do
    # Checkout a database connection for this test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)

    # Start the rate limiter if not already started
    case GenServer.whereis(MetadataRelay.RateLimiter) do
      nil -> start_supervised!(MetadataRelay.RateLimiter)
      _pid -> :ok
    end

    # Clear the rate limiter table before each test
    :ets.delete_all_objects(:rate_limiter)

    :ok
  end

  # Submit a crash report through the full router pipeline, mirroring what a
  # real mydia instance sends: an empty `stacktrace` plus a `metadata` map
  # describing the crash site.
  defp report(crash_report) do
    Plug.Test.conn(:post, "/crashes/report", crash_report)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> Router.call([])
  end

  defp stored_errors do
    MetadataRelay.Repo.all(from(e in ErrorTracker.Error, order_by: e.id))
  end

  defp stored_occurrences do
    MetadataRelay.Repo.all(from(o in ErrorTracker.Occurrence, order_by: o.id))
  end

  # The body the Flutter player's CrashReporter sends, varying only the crash
  # site so two reports land in two groups.
  defp player_report(file, line) do
    %{
      "source" => "player",
      "error_type" => "StateError",
      "error_message" => "Bad state: No element",
      "stacktrace" => [
        %{"function" => "PlayerController.seek", "file" => file, "line" => line}
      ],
      "version" => "0.52.1",
      "environment" => "prod",
      "metadata" => %{
        "capture" => "zone",
        "manual" => false,
        "platform" => "android",
        "function" => "PlayerController.seek",
        "file" => file,
        "line" => line
      }
    }
  end

  describe "POST /crashes/report" do
    test "successfully stores a crash report with valid data" do
      crash_report = %{
        "error_type" => "RuntimeError",
        "error_message" => "Test error message",
        "stacktrace" => [
          %{"file" => "lib/mydia/test.ex", "line" => 42, "function" => "test_function"},
          %{"file" => "lib/mydia/other.ex", "line" => 100}
        ],
        "version" => "1.0.0",
        "environment" => "test"
      }

      conn =
        Plug.Test.conn(:post, "/crashes/report", crash_report)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 201

      assert %{"status" => "created", "message" => "Crash report received"} =
               Jason.decode!(conn.resp_body)
    end

    test "returns 400 when required fields are missing" do
      # Missing error_message and stacktrace
      crash_report = %{
        "error_type" => "RuntimeError"
      }

      conn =
        Plug.Test.conn(:post, "/crashes/report", crash_report)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 400
      assert %{"error" => "Validation failed", "errors" => errors} = Jason.decode!(conn.resp_body)
      assert "Missing required field: error_message" in errors
      assert "Missing required field: stacktrace" in errors
    end

    test "returns 400 when stacktrace is not a list" do
      crash_report = %{
        "error_type" => "RuntimeError",
        "error_message" => "Test error",
        "stacktrace" => "not a list"
      }

      conn =
        Plug.Test.conn(:post, "/crashes/report", crash_report)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 400
      assert %{"error" => "Validation failed", "errors" => errors} = Jason.decode!(conn.resp_body)
      assert "stacktrace must be a list" in errors
    end

    test "handles malformed JSON gracefully" do
      # Send empty body_params to simulate malformed JSON
      # (Plug.Parsers would raise in real scenario, but router handles empty params)
      conn =
        Plug.Test.conn(:post, "/crashes/report", %{})
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      # Should return 400 for missing required fields
      assert conn.status == 400
      assert %{"error" => "Validation failed"} = Jason.decode!(conn.resp_body)
    end

    test "rate limits excessive requests from same IP" do
      # Clear rate limiter manually for this test
      :ets.delete_all_objects(:rate_limiter)

      crash_report = %{
        "error_type" => "RuntimeError",
        "error_message" => "Test error",
        "stacktrace" => [
          %{"file" => "lib/test.ex", "line" => 10}
        ]
      }

      # Make 10 requests (the limit) - all should succeed
      results =
        for i <- 1..10 do
          conn =
            Plug.Test.conn(:post, "/crashes/report", crash_report)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
            |> Router.call([])

          {i, conn.status}
        end

      # All 10 should succeed
      assert Enum.all?(results, fn {_i, status} -> status == 201 end),
             "Expected all 10 requests to succeed, got: #{inspect(results)}"

      # 11th request should be rate limited
      conn =
        Plug.Test.conn(:post, "/crashes/report", crash_report)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Router.call([])

      assert conn.status == 429
      assert %{"error" => "Too many requests"} = Jason.decode!(conn.resp_body)
      assert ["60"] = Plug.Conn.get_resp_header(conn, "retry-after")
    end

    test "a player report is labelled player and its Dart frames keep crash sites apart" do
      assert report(player_report("package:player/core/player/player_controller.dart", 412)).status ==
               201

      assert report(player_report("package:player/core/cast/cast_session_manager.dart", 88)).status ==
               201

      errors = stored_errors()
      assert length(errors) == 2
      assert Enum.any?(errors, &(&1.source_line =~ "player_controller.dart:412"))
      assert Enum.any?(errors, &(&1.source_line =~ "cast_session_manager.dart:88"))

      assert Enum.map(stored_occurrences(), & &1.context["source"]) == ["player", "player"]
    end

    test "a report without a source is labelled server" do
      assert report(%{
               "error_type" => "RuntimeError",
               "error_message" => "boom",
               "stacktrace" => [%{"file" => "lib/mydia/a.ex", "line" => 1}]
             }).status == 201

      assert [occurrence] = stored_occurrences()
      assert occurrence.context["source"] == "server"
    end

    test "a source outside the closed set is labelled server" do
      assert report(%{
               "source" => "web",
               "error_type" => "RuntimeError",
               "error_message" => "boom",
               "stacktrace" => [%{"file" => "lib/mydia/a.ex", "line" => 1}]
             }).status == 201

      assert [occurrence] = stored_occurrences()
      assert occurrence.context["source"] == "server"
    end
  end

  describe "crash report fingerprinting" do
    # Real mydia instances send an empty stacktrace and put the crash site in
    # `metadata`. These reproduce the production bug where every report collapsed
    # into a single ErrorTracker record because kind was hardcoded to
    # "RuntimeError" and no source info was derived from `metadata`.
    test "distinct crash sites are stored as distinct errors" do
      assert report(%{
               "error_type" => "RuntimeError",
               "error_message" => "{:path_not_found, \"/downloads/complete/foo.mkv\"}",
               "stacktrace" => [],
               "metadata" => %{
                 "file" => "lib/mydia/jobs/media_import.ex",
                 "function" => "import_download/2",
                 "line" => 299,
                 "module" => "Elixir.Mydia.Jobs.MediaImport"
               },
               "version" => "0.11.1"
             }).status == 201

      assert report(%{
               "error_type" => "RuntimeError",
               "error_message" => "value too long for type character varying(255)",
               "stacktrace" => [],
               "metadata" => %{
                 "file" => "lib/mydia/jobs/library_scanner.ex",
                 "function" => "scan/1",
                 "line" => 248,
                 "module" => "Elixir.Mydia.Jobs.LibraryScanner"
               },
               "version" => "0.11.1"
             }).status == 201

      errors = stored_errors()

      assert length(errors) == 2,
             "expected two distinct errors, got #{length(errors)}: " <>
               inspect(Enum.map(errors, & &1.source_line))

      assert Enum.map(errors, & &1.source_line) |> Enum.uniq() |> length() == 2

      assert Enum.any?(errors, &(&1.source_line =~ "media_import.ex:299"))
      assert Enum.any?(errors, &(&1.source_line =~ "library_scanner.ex:248"))
    end

    test "client stacktrace module is folded into source_function so same-named functions in different modules stay distinct" do
      assert report(%{
               "error_type" => "RuntimeError",
               "error_message" => "boom",
               "stacktrace" => [
                 %{
                   "file" => "lib/mydia/a.ex",
                   "line" => 10,
                   "function" => "handle/1",
                   "module" => "Elixir.Mydia.A"
                 }
               ]
             }).status == 201

      assert report(%{
               "error_type" => "RuntimeError",
               "error_message" => "boom",
               "stacktrace" => [
                 %{
                   "file" => "lib/mydia/b.ex",
                   "line" => 10,
                   "function" => "handle/1",
                   "module" => "Elixir.Mydia.B"
                 }
               ]
             }).status == 201

      errors = stored_errors()

      assert length(errors) == 2,
             "expected two distinct errors, got #{length(errors)}: " <>
               inspect(Enum.map(errors, & &1.source_function))

      assert Enum.any?(errors, &(&1.source_function =~ "Mydia.A.handle"))
      assert Enum.any?(errors, &(&1.source_function =~ "Mydia.B.handle"))
    end

    test "the reported error_type is preserved as the error kind" do
      assert report(%{
               "error_type" => "CaseClauseError",
               "error_message" => "no case clause matching: {:error, :expired}",
               "stacktrace" => [],
               "metadata" => %{
                 "file" => "lib/mydia/indexers/flaresolverr.ex",
                 "function" => "request/2",
                 "line" => 232,
                 "module" => "Elixir.Mydia.Indexers.Flaresolverr"
               },
               "version" => "0.11.1"
             }).status == 201

      assert [error] = stored_errors()
      assert error.kind == "CaseClauseError"
    end
  end
end
