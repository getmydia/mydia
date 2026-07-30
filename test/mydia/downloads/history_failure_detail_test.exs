defmodule Mydia.Downloads.HistoryFailureDetailTest do
  @moduledoc """
  Guards the field separation that #237 depends on: `error_message` stays
  bound to the database column, while client-reported failure detail
  travels in its own fields.

  `DownloadMonitor` selects unhandled failures with `is_nil(error_message)`
  (lib/mydia/jobs/download_monitor.ex:91). If client detail ever leaks into
  `error_message`, every failed download looks already-handled and stops
  being processed — silently. That is what the last test here prevents.
  """
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Structs.EnrichedDownload

  describe "EnrichedDownload failure fields" do
    test "carries a client failure category and detail" do
      enriched =
        EnrichedDownload.new(%{
          id: "d-1",
          title: "Some.Release",
          download_client: "torbox",
          status: "failed",
          client_failure_category: :missing_files,
          client_error_detail: "missingFiles"
        })

      assert enriched.client_failure_category == :missing_files
      assert enriched.client_error_detail == "missingFiles"
    end

    test "error_message stays nil when only client detail is present" do
      enriched =
        EnrichedDownload.new(%{
          id: "d-2",
          title: "Some.Release",
          download_client: "torbox",
          status: "failed",
          client_failure_category: :no_peers,
          client_error_detail: "dead"
        })

      # If this ever fails, the DownloadMonitor unhandled-failure guard is
      # broken and failed downloads will stop being blacklisted at all.
      assert enriched.error_message == nil
    end

    test "defaults both fields to nil for clients that do not classify" do
      enriched =
        EnrichedDownload.new(%{
          id: "d-3",
          title: "Some.Release",
          download_client: "qbittorrent",
          status: "failed"
        })

      assert enriched.client_failure_category == nil
      assert enriched.client_error_detail == nil
    end
  end
end
