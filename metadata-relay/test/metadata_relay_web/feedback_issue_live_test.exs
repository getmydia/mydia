defmodule MetadataRelayWeb.FeedbackIssueLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn
  import MetadataRelay.Test.GitHubHelpers

  alias MetadataRelay.Feedback
  alias MetadataRelay.Feedback.Submission
  alias MetadataRelay.Repo

  @endpoint MetadataRelayWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    # start_async runs Feedback.file_issue/3 in a Task, which needs to share
    # this test's database connection.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Repo.delete_all(Submission)

    previous_users = Application.get_env(:metadata_relay, :dashboard_github_users)

    previous_github =
      put_github_config(client_id: "cid", client_secret: "csecret", repo: "getmydia/mydia")

    Application.put_env(:metadata_relay, :dashboard_github_users, ["arsfeld"])

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      case previous_users do
        nil -> Application.delete_env(:metadata_relay, :dashboard_github_users)
        value -> Application.put_env(:metadata_relay, :dashboard_github_users, value)
      end

      restore_github_config(previous_github)
      clear_github_adapter()
    end)

    :ok
  end

  test "the file issue button is absent without a GitHub token" do
    Application.delete_env(:metadata_relay, :dashboard_github_users)
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "It broke"})

    {:ok, view, _html} = live(basic_conn(), "/feedback")

    refute has_element?(view, "#file-issue-#{submission.id}")
  end

  test "the modal opens prefilled from the submission" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Playback stalls"})

    {:ok, view, _html} = live(signed_in_conn(), "/feedback")

    html =
      view
      |> element("#file-issue-#{submission.id}")
      |> render_click()

    assert has_element?(view, "#issue-modal")
    assert has_element?(view, "#issue-title[value='Playback stalls']")
    assert html =~ "Playback stalls"
  end

  test "creating an issue records the ref and closes the modal" do
    set_github_adapter(fn request ->
      {request,
       Req.Response.new(
         status: 201,
         body: %{
           "number" => 123,
           "html_url" => "https://github.com/getmydia/mydia/issues/123"
         }
       )}
    end)

    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Playback stalls"})

    {:ok, view, _html} = live(signed_in_conn(), "/feedback")

    view |> element("#file-issue-#{submission.id}") |> render_click()

    view
    |> form("#issue-form", %{"title" => "Playback stalls", "body" => "Edited body"})
    |> render_submit()

    render_async(view)

    reloaded = Feedback.get_submission!(submission.id)
    assert reloaded.github_ref == "#123"
    assert reloaded.github_issue_url == "https://github.com/getmydia/mydia/issues/123"
    assert reloaded.state == "filed"

    refute has_element?(view, "#issue-modal")
  end

  test "a failure keeps the modal open with the edited body" do
    set_github_adapter(fn request ->
      {request, Req.Response.new(status: 422, body: %{"message" => "Validation Failed"})}
    end)

    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Playback stalls"})

    {:ok, view, _html} = live(signed_in_conn(), "/feedback")

    view |> element("#file-issue-#{submission.id}") |> render_click()

    view
    |> form("#issue-form", %{"title" => "Retitled", "body" => "Edited body"})
    |> render_submit()

    html = render_async(view)

    assert has_element?(view, "#issue-modal")
    assert has_element?(view, "#issue-modal-error", "Validation Failed")
    assert html =~ "Edited body"
    assert has_element?(view, "#issue-title[value='Retitled']")

    assert Feedback.get_submission!(submission.id).github_ref == nil
  end

  test "cancelling closes the modal without filing" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Playback stalls"})

    {:ok, view, _html} = live(signed_in_conn(), "/feedback")

    view |> element("#file-issue-#{submission.id}") |> render_click()
    view |> element("#issue-cancel") |> render_click()

    refute has_element?(view, "#issue-modal")
    assert Feedback.get_submission!(submission.id).github_ref == nil
  end

  test "a filed submission links to its issue instead of offering the button" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Playback stalls"})

    {:ok, _filed} =
      submission
      |> Submission.filed_changeset("#123", "https://github.com/getmydia/mydia/issues/123")
      |> Repo.update()

    {:ok, view, _html} = live(signed_in_conn(), "/feedback")

    view
    |> form("#feedback-filters", %{"filters" => %{"state" => "all", "type" => "all"}})
    |> render_change()

    refute has_element?(view, "#file-issue-#{submission.id}")

    assert has_element?(
             view,
             "a[href='https://github.com/getmydia/mydia/issues/123']",
             "Filed as #123"
           )
  end

  test "the filed filter and stat tile are present" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Playback stalls"})
    {:ok, _filed} = Feedback.update_state(submission, "filed")

    {:ok, view, _html} = live(signed_in_conn(), "/feedback")

    assert has_element?(view, "#feedback-stat-filed")

    view
    |> form("#feedback-filters", %{"filters" => %{"state" => "filed", "type" => "all"}})
    |> render_change()

    assert has_element?(view, "#feedback-#{submission.id}")
  end

  defp signed_in_conn do
    build_conn()
    |> init_test_session(github_login: "arsfeld", github_token: "gho_token")
  end

  defp basic_conn do
    build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("admin:admin"))
  end
end
