defmodule Mydia.Downloads.Client.FailureCategoryTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.FailureCategory

  describe "slug/1" do
    test "nil maps to the pre-existing fallback slug" do
      assert FailureCategory.slug(nil) == "client_reported_failure"
    end

    test "each category stringifies to its own slug" do
      assert FailureCategory.slug(:no_peers) == "no_peers"
      assert FailureCategory.slug(:missing_files) == "missing_files"
      assert FailureCategory.slug(:rejected_content) == "rejected_content"
      assert FailureCategory.slug(:provider_error) == "provider_error"
    end
  end

  describe "label/1" do
    test "humanizes a category atom" do
      assert FailureCategory.label(:missing_files) == "missing files"
      assert FailureCategory.label(:no_peers) == "no peers"
    end

    test "humanizes the fallback slug read back from the database" do
      assert FailureCategory.label("client_reported_failure") == "client reported failure"
    end

    test "humanizes an unknown legacy slug rather than raising" do
      assert FailureCategory.label("some_legacy_value") == "some legacy value"
    end

    test "nil is treated as the fallback" do
      assert FailureCategory.label(nil) == "client reported failure"
    end
  end

  describe "message/3" do
    test "composes client, label and native detail" do
      assert FailureCategory.message("torbox", :missing_files, "missingFiles") ==
               "torbox reported missing files: missingFiles"
    end

    test "falls back to the pre-existing constant when there is nothing to say" do
      assert FailureCategory.message("qbittorrent", nil, nil) == "Download failed in client"
    end

    test "omits the detail suffix when only a category is known" do
      assert FailureCategory.message("premiumize", :provider_error, nil) ==
               "premiumize reported provider error"
    end

    test "substitutes a generic subject when the client name is missing" do
      assert FailureCategory.message(nil, :no_peers, "dead") ==
               "Download client reported no peers: dead"
    end

    test "treats a blank detail as absent" do
      assert FailureCategory.message("torbox", :provider_error, "   ") ==
               "torbox reported provider error"
    end

    # This is the shape AllDebrid actually produces for undocumented
    # `statusCode >= 12` values: no category, but a native status text
    # worth surfacing. The category label must not appear, or the
    # sentence reads as the redundant "reported client reported failure".
    test "drops the redundant label when there is a detail but no category" do
      assert FailureCategory.message("my-debrid", nil, "Something new") ==
               "my-debrid reported: Something new"
    end

    test "substitutes a generic subject when client is blank, with a detail but no category" do
      assert FailureCategory.message(nil, nil, "Something new") ==
               "Download client reported: Something new"
    end
  end
end
