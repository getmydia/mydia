defmodule MydiaWeb.AdminIndexersLive.SearchStatsTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.SettingsFixtures

  alias Mydia.Accounts
  alias Mydia.Indexers.SearchStats.Event
  alias Mydia.Repo

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)
    start_supervised!(Mydia.Indexers.Health)
    Mydia.Indexers.register_adapters()

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    busy =
      indexer_config_fixture(%{
        name: "Fictional Relay",
        type: :prowlarr,
        base_url: "http://localhost:1"
      })

    quiet =
      indexer_config_fixture(%{
        name: "Imaginary Relay",
        type: :prowlarr,
        base_url: "http://localhost:2"
      })

    %{conn: conn, busy: busy, quiet: quiet}
  end

  defp insert!(indexer, attrs) do
    Repo.insert!(
      struct(
        Event,
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            indexer_id: indexer.id,
            indexer_name: indexer.name,
            indexer_type: "prowlarr",
            kind: "search",
            outcome: "ok",
            duration_ms: 400,
            result_count: 3,
            inserted_at: DateTime.utc_now()
          },
          attrs
        )
      )
    )
  end

  test "shows a strip per indexer, empty when it has no rows", %{
    conn: conn,
    busy: busy,
    quiet: quiet
  } do
    insert!(busy, %{})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    assert has_element?(view, "#indexer-stats-#{busy.id}-none")
    assert has_element?(view, "#indexer-stats-#{quiet.id}", "No searches yet")
  end

  test "the window toggle switches to seven days", %{conn: conn, busy: busy} do
    insert!(busy, %{inserted_at: DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    refute has_element?(view, "#indexer-stats-#{busy.id}-none")

    view |> element("#indexer-stats-window-week") |> render_click()
    assert has_element?(view, "#indexer-stats-#{busy.id}-none")
  end

  test "a strip opens and closes the recent failures dialog", %{conn: conn, busy: busy} do
    insert!(busy, %{})
    failure = insert!(busy, %{outcome: "timeout", error_message: "Cardigann call timed out"})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    view |> element("#indexer-stats-#{busy.id}-none") |> render_click()
    assert has_element?(view, "#indexer-failure-#{failure.id}", "Cardigann call timed out")

    render_hook(view, "close_search_failures", %{})
    refute has_element?(view, "#indexer-failures")
  end

  test "a mostly failing indexer colors its success rate as an error", %{
    conn: conn,
    busy: busy
  } do
    insert!(busy, %{})
    for _ <- 1..3, do: insert!(busy, %{outcome: "error", error_message: "boom"})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    assert has_element?(view, "#indexer-stats-#{busy.id}-none-success.text-error", "25%")
  end

  test "a mostly healthy indexer colors its success rate as a warning", %{
    conn: conn,
    busy: busy
  } do
    for _ <- 1..9, do: insert!(busy, %{})
    insert!(busy, %{outcome: "error", error_message: "boom"})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    assert has_element?(view, "#indexer-stats-#{busy.id}-none-success.text-warning", "90%")
  end

  test "a rate just under the healthy threshold is not rounded up to it", %{
    conn: conn,
    busy: busy
  } do
    for _ <- 1..35, do: insert!(busy, %{})
    for _ <- 1..2, do: insert!(busy, %{outcome: "error", error_message: "boom"})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    assert has_element?(view, "#indexer-stats-#{busy.id}-none-success.text-warning", "94%")
  end

  test "the success percent is not skewed by float error", %{conn: conn, busy: busy} do
    for _ <- 1..29, do: insert!(busy, %{})
    for _ <- 1..71, do: insert!(busy, %{outcome: "error", error_message: "boom"})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    assert has_element?(view, "#indexer-stats-#{busy.id}-none-success.text-error", "29%")
  end

  test "a healthy indexer colors its success rate as success", %{conn: conn, busy: busy} do
    insert!(busy, %{})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    assert has_element?(view, "#indexer-stats-#{busy.id}-none-success.text-success", "100%")
    refute has_element?(view, "#indexer-stats-#{busy.id}-none-timeouts.text-warning")
  end

  test "both engines of one indexer share a row, each labelled", %{conn: conn, busy: busy} do
    insert!(busy, %{engine: "builtin"})
    insert!(busy, %{engine: "prowlarr"})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    row = "#indexer-stats-#{busy.id}"

    assert has_element?(view, "#{row} > #indexer-stats-#{busy.id}-builtin")
    assert has_element?(view, "#{row} > #indexer-stats-#{busy.id}-prowlarr")
    assert has_element?(view, "#indexer-stats-#{busy.id}-builtin-engine", "Built-in")
    assert has_element?(view, "#indexer-stats-#{busy.id}-prowlarr-engine", "Prowlarr")
    refute has_element?(view, "#indexer-stats-#{busy.id}-none-engine")
  end

  test "timeouts are flagged as a warning", %{conn: conn, busy: busy} do
    insert!(busy, %{})
    insert!(busy, %{outcome: "timeout", error_message: "Cardigann call timed out"})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    assert has_element?(view, "#indexer-stats-#{busy.id}-none-timeouts.text-warning", "1")
  end
end
