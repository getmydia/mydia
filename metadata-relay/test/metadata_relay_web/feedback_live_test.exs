defmodule MetadataRelayWeb.FeedbackLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ecto.Query
  import Plug.Conn

  alias MetadataRelay.Feedback
  alias MetadataRelay.Feedback.Submission
  alias MetadataRelay.Repo

  @endpoint MetadataRelayWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Submission)
    :ok
  end

  test "lists unread rows by default newest first" do
    {:ok, unread_old} = Feedback.create_submission(%{type: "bug", message: "Unread old"})
    {:ok, read} = Feedback.create_submission(%{type: "idea", message: "Already handled"})
    {:ok, archived} = Feedback.create_submission(%{type: "question", message: "Stored away"})
    {:ok, unread_new} = Feedback.create_submission(%{type: "bug", message: "Unread new"})

    Repo.update_all(from(s in Submission, where: s.id == ^unread_old.id),
      set: [inserted_at: ~U[2026-01-01 00:00:00Z]]
    )

    Repo.update_all(from(s in Submission, where: s.id == ^unread_new.id),
      set: [inserted_at: ~U[2026-01-02 00:00:00Z]]
    )

    {:ok, _read} = Feedback.update_state(read, "read")
    {:ok, _archived} = Feedback.update_state(archived, "archived")

    {:ok, view, html} = live(authed_conn(), "/feedback")

    assert has_element?(view, "#feedback-dashboard")
    assert has_element?(view, "#feedback-#{unread_new.id}")
    assert has_element?(view, "#feedback-#{unread_old.id}")
    refute has_element?(view, "#feedback-#{read.id}")
    refute has_element?(view, "#feedback-#{archived.id}")

    assert :binary.match(html, "feedback-#{unread_new.id}") <
             :binary.match(html, "feedback-#{unread_old.id}")
  end

  test "switching state filter to all surfaces all rows" do
    {:ok, unread} = Feedback.create_submission(%{type: "bug", message: "Unread"})
    {:ok, read} = Feedback.create_submission(%{type: "idea", message: "Read"})
    {:ok, archived} = Feedback.create_submission(%{type: "question", message: "Archived"})
    {:ok, _read} = Feedback.update_state(read, "read")
    {:ok, _archived} = Feedback.update_state(archived, "archived")

    {:ok, view, _html} = live(authed_conn(), "/feedback")

    html =
      view
      |> form("#feedback-filters", %{"filters" => %{"state" => "all", "type" => "all"}})
      |> render_change()

    assert html =~ "Showing 3 matching submissions"
    assert has_element?(view, "#feedback-#{unread.id}")
    assert has_element?(view, "#feedback-#{read.id}")
    assert has_element?(view, "#feedback-#{archived.id}")
  end

  test "invalid filter values fall back to safe defaults" do
    {:ok, unread} = Feedback.create_submission(%{type: "bug", message: "Unread"})
    {:ok, read} = Feedback.create_submission(%{type: "idea", message: "Read"})
    {:ok, _read} = Feedback.update_state(read, "read")

    {:ok, view, _html} = live(authed_conn(), "/feedback")

    html = render_change(view, "filter", %{"filters" => %{"state" => "bogus", "type" => "bogus"}})

    assert html =~ "State: all states"
    assert html =~ "Type: all types"
    assert has_element?(view, "#feedback-#{unread.id}")
    assert has_element?(view, "#feedback-#{read.id}")
  end

  test "mark read transitions an unread row" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Unread"})

    {:ok, view, _html} = live(authed_conn(), "/feedback")

    view
    |> element("#mark-read-#{submission.id}")
    |> render_click()

    assert Feedback.get_submission!(submission.id).state == "read"
    refute has_element?(view, "#mark-read-#{submission.id}")
  end

  test "archive transitions a read row" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Read"})
    {:ok, submission} = Feedback.update_state(submission, "read")

    {:ok, view, _html} = live(authed_conn(), "/feedback")

    view
    |> form("#feedback-filters", %{"filters" => %{"state" => "all", "type" => "all"}})
    |> render_change()

    view
    |> element("#archive-#{submission.id}")
    |> render_click()

    assert Feedback.get_submission!(submission.id).state == "archived"
    refute has_element?(view, "#archive-#{submission.id}")
  end

  test "saving github_ref persists the tag" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Unread"})

    {:ok, view, _html} = live(authed_conn(), "/feedback")

    html =
      view
      |> form("#feedback-github-ref-#{submission.id}", %{
        "github_ref" => "gh#123"
      })
      |> render_submit()

    assert Feedback.get_submission!(submission.id).github_ref == "gh#123"
    assert html =~ "Filed as gh#123"
    assert has_element?(view, "#github-ref-input-#{submission.id}[value='gh#123']")
  end

  test "saving github_ref for a missing row shows an error" do
    {:ok, view, _html} = live(authed_conn(), "/feedback")

    html =
      render_hook(view, "save_github_ref", %{
        "id" => Ecto.UUID.generate(),
        "github_ref" => "gh#1"
      })

    assert html =~ "Feedback no longer exists."
    assert has_element?(view, "#dashboard-flash-error", "Feedback no longer exists.")
  end

  test "saving github_ref with an invalid id shows an error" do
    {:ok, view, _html} = live(authed_conn(), "/feedback")

    html =
      render_hook(view, "save_github_ref", %{
        "id" => "not-a-uuid",
        "github_ref" => "gh#1"
      })

    assert html =~ "Feedback no longer exists."
    assert has_element?(view, "#dashboard-flash-error", "Feedback no longer exists.")
  end

  test "a focus parameter expands the targeted submission" do
    long_message = String.duplicate("This message is long enough to be truncated. ", 12)
    {:ok, focused} = Feedback.create_submission(%{type: "bug", message: long_message})
    {:ok, other} = Feedback.create_submission(%{type: "bug", message: long_message})

    {:ok, view, _html} = live(authed_conn(), "/feedback?focus=#{focused.id}")

    assert has_element?(view, "#toggle-expand-#{focused.id}", "Collapse message")
    assert has_element?(view, "#toggle-expand-#{other.id}", "Expand message")
  end

  test "an unknown focus parameter expands nothing" do
    long_message = String.duplicate("This message is long enough to be truncated. ", 12)
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: long_message})

    {:ok, view, _html} = live(authed_conn(), "/feedback?focus=#{Ecto.UUID.generate()}")

    assert has_element?(view, "#toggle-expand-#{submission.id}", "Expand message")
  end

  defp authed_conn do
    build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("admin:admin"))
  end
end
