defmodule MetadataRelay.FeedbackFileIssueTest do
  use ExUnit.Case, async: false

  import MetadataRelay.Test.GitHubHelpers

  alias MetadataRelay.Feedback
  alias MetadataRelay.Feedback.Submission
  alias MetadataRelay.Repo

  @attrs %{title: "Playback stalls", body: "It broke", labels: ["bug"]}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Submission)

    previous =
      put_github_config(client_id: "cid", client_secret: "csecret", repo: "getmydia/mydia")

    on_exit(fn ->
      restore_github_config(previous)
      clear_github_adapter()
    end)

    :ok
  end

  test "a successful call records the ref, the URL, and the filed state" do
    stub_created(123)

    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "It broke"})

    assert {:ok, filed} = Feedback.file_issue(submission, @attrs, "gho_token")

    assert filed.github_ref == "#123"
    assert filed.github_issue_url == "https://github.com/getmydia/mydia/issues/123"
    assert filed.state == "filed"

    reloaded = Feedback.get_submission!(submission.id)
    assert reloaded.github_ref == "#123"
    assert reloaded.state == "filed"
  end

  test "an archived submission stays archived" do
    stub_created(124)

    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "It broke"})
    {:ok, submission} = Feedback.update_state(submission, "archived")

    assert {:ok, filed} = Feedback.file_issue(submission, @attrs, "gho_token")

    assert filed.state == "archived"
    assert filed.github_ref == "#124"
  end

  test "a failure leaves the row untouched" do
    set_github_adapter(fn request ->
      {request, Req.Response.new(status: 422, body: %{"message" => "Validation Failed"})}
    end)

    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "It broke"})

    assert {:error, {:unprocessable, "Validation Failed"}} =
             Feedback.file_issue(submission, @attrs, "gho_token")

    reloaded = Feedback.get_submission!(submission.id)
    assert reloaded.github_ref == nil
    assert reloaded.github_issue_url == nil
    assert reloaded.state == "unread"
  end

  defp stub_created(number) do
    set_github_adapter(fn request ->
      {request,
       Req.Response.new(
         status: 201,
         body: %{
           "number" => number,
           "html_url" => "https://github.com/getmydia/mydia/issues/#{number}"
         }
       )}
    end)
  end
end
