defmodule Mydia.Metrics.TagsTest do
  use ExUnit.Case, async: true

  alias Mydia.Metrics.Tags

  test "http/1 uses the route pattern, method and status class" do
    conn = %Plug.Conn{method: "GET", status: 404}

    assert Tags.http(%{route: "/api/v1/media/:id", conn: conn}) == %{
             route: "/api/v1/media/:id",
             method: "GET",
             status_class: "4xx"
           }
  end

  test "http/1 never raises on junk" do
    assert %{route: "unknown", method: "unknown", status_class: "unknown"} = Tags.http(:junk)
  end

  test "keep_http?/1 drops the scrape and health routes" do
    refute Tags.keep_http?(%{route: "/metrics"})
    refute Tags.keep_http?(%{route: "/health"})
    assert Tags.keep_http?(%{route: "/api/v1/media/:id"})
    assert Tags.keep_http?(:junk)
  end

  test "oban_job/1 names the queue and worker" do
    job = %Oban.Job{queue: "media", worker: "Mydia.Jobs.LibraryScanner"}
    assert Tags.oban_job(%{job: job}) == %{queue: "media", worker: "Mydia.Jobs.LibraryScanner"}
    assert Tags.oban_job(:junk) == %{queue: "unknown", worker: "unknown"}
  end

  describe "indexer_search/1" do
    test "stringifies the labels and names a missing engine" do
      assert Tags.indexer_search(%{
               indexer_name: "Fictional Tracker",
               engine: nil,
               kind: :search,
               outcome: :timeout
             }) == %{
               indexer_name: "Fictional Tracker",
               engine: "none",
               kind: "search",
               outcome: "timeout"
             }
    end

    test "never raises" do
      assert %{indexer_name: "unknown"} = Tags.indexer_search(:garbage)
    end
  end
end
