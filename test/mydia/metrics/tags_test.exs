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
end
