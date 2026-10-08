defmodule MydiaWeb.JobsLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  setup do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})
    {:ok, job} = Oban.insert(Mydia.Jobs.LibraryScanner.new(%{}))
    %{job: job}
  end

  test "job history is an admin table with icon actions", %{conn: conn, job: job} do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    assert has_element?(view, "#job-history table.table-zebra tr#job-#{job.id}")
    assert has_element?(view, ~s(#job-details-#{job.id}[title="Details"]))
    assert has_element?(view, ~s(#cancel-job-#{job.id}.text-error[data-confirm]))
  end

  test "details open in the shared modal and close", %{conn: conn, job: job} do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    view |> element("#job-details-#{job.id}") |> render_click()
    assert has_element?(view, "#job-details-modal .modal-box.max-w-4xl")

    render_click(view, "close_job_details_modal", %{})
    refute has_element?(view, "#job-details-modal")
  end

  test "filtering by state narrows the history", %{conn: conn, job: job} do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    view
    |> form("#jobs-filter-form", %{"worker" => "", "state" => "completed"})
    |> render_change()

    refute has_element?(view, "tr#job-#{job.id}")
    assert has_element?(view, "#job-history-empty")
  end

  test "triggering asks first in the shared modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")

    render_click(view, "confirm_trigger_job", %{"worker" => "Mydia.Jobs.LibraryScanner"})
    assert has_element?(view, "#trigger-job-modal")

    render_click(view, "close_trigger_job_modal", %{})
    refute has_element?(view, "#trigger-job-modal")
  end
end
