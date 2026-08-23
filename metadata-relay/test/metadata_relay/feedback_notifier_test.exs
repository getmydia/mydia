defmodule MetadataRelay.FeedbackNotifierTest do
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias MetadataRelay.Feedback
  alias MetadataRelay.Feedback.Notifier
  alias MetadataRelay.Feedback.Submission
  alias MetadataRelay.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Submission)
    :ok
  end

  test "the dashboard link carries a focus parameter as well as the anchor" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Broken"})

    :ok = deliver(submission)

    assert_email_sent(fn email ->
      assert email.text_body =~
               "https://relay.example.com/feedback?focus=#{submission.id}#feedback-#{submission.id}"
    end)
  end

  test "dashboard_url trims a trailing slash" do
    assert Feedback.dashboard_url() == "https://relay.example.com"
  end

  defp deliver(submission) do
    case Notifier.deliver_new_submission(submission) do
      {:ok, _} -> :ok
      :ok -> :ok
    end
  end
end
