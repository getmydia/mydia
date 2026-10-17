defmodule MetadataRelayWeb.InstallsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias MetadataRelay.{Repo, UpdateCheck}

  @endpoint MetadataRelayWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp authed_conn do
    build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("admin:admin"))
  end

  test "requires the dashboard credentials" do
    assert build_conn() |> get("/installs") |> Map.get(:status) == 401
  end

  test "shows an empty state before any install has checked" do
    {:ok, view, _html} = live(authed_conn(), "/installs")

    assert has_element?(view, "#installs-empty")
  end

  test "lists weekly counts and the latest week's breakdowns" do
    {:ok, _} =
      UpdateCheck.record(%{
        "install_id" => String.duplicate("c", 64),
        "version" => "0.16.0",
        "arch" => "aarch64",
        "db" => "postgres"
      })

    week = UpdateCheck.week_of(Date.utc_today())
    {:ok, view, _html} = live(authed_conn(), "/installs")

    assert has_element?(view, "#installs-week-#{week}", "1")
    assert has_element?(view, "#installs-by-version", "0.16.0")
    assert has_element?(view, "#installs-by-architecture", "aarch64")
    assert has_element?(view, "#installs-by-database", "postgres")
  end
end
