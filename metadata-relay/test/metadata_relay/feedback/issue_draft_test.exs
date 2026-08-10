defmodule MetadataRelay.Feedback.IssueDraftTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Feedback.IssueDraft
  alias MetadataRelay.Feedback.Submission

  @id "11111111-2222-3333-4444-555555555555"

  test "title uses the first non-empty line with whitespace collapsed" do
    draft = draft_for(%{message: "\n\n  Playback   stalls  \nmore detail here"})

    assert draft.title == "Playback stalls"
  end

  test "title truncates at 72 characters with an ellipsis" do
    message = String.duplicate("a", 80)
    draft = draft_for(%{message: message})

    assert String.length(draft.title) == 73
    assert String.ends_with?(draft.title, "…")
    assert String.starts_with?(draft.title, String.duplicate("a", 72))
  end

  test "title keeps a message exactly at the limit intact" do
    message = String.duplicate("a", 72)
    draft = draft_for(%{message: message})

    assert draft.title == message
  end

  test "title falls back to the type when no usable line exists" do
    draft = draft_for(%{message: "   \n  \n", type: "idea"})

    assert draft.title == "Feedback: idea"
  end

  test "body carries the message, the version, and the backlink" do
    draft = draft_for(%{message: "It broke", mydia_version: "1.4.2"})

    assert draft.body == """
           It broke

           ---
           Reported via in-app feedback from Mydia 1.4.2.
           Feedback: https://relay.example.com/feedback?focus=#{@id}#feedback-#{@id}\
           """
  end

  test "body omits the version when it is unknown" do
    draft = draft_for(%{message: "It broke", mydia_version: nil})

    assert draft.body =~ "Reported via in-app feedback.\n"
    refute draft.body =~ "from Mydia"
  end

  test "body omits the backlink when no dashboard URL is configured" do
    draft = draft_for(%{message: "It broke"}, nil)

    refute draft.body =~ "Feedback:"
    assert draft.body =~ "Reported via in-app feedback"
  end

  test "identifying fields never reach the draft" do
    draft =
      draft_for(%{
        message: "It broke",
        contact: "reporter@example.com",
        source_ip: "203.0.113.7",
        instance_id: "instance-abcdef123456"
      })

    refute draft.title =~ "reporter@example.com"
    refute draft.body =~ "reporter@example.com"
    refute draft.body =~ "203.0.113.7"
    refute draft.body =~ "instance-abcdef123456"
  end

  test "labels map from the feedback type" do
    assert draft_for(%{type: "bug"}).labels == ["bug"]
    assert draft_for(%{type: "idea"}).labels == ["enhancement"]
    assert draft_for(%{type: "question"}).labels == ["question"]
  end

  defp draft_for(attrs, dashboard_url \\ "https://relay.example.com") do
    submission =
      struct(
        %Submission{
          id: @id,
          type: "bug",
          message: "Something",
          state: "unread"
        },
        attrs
      )

    IssueDraft.from_submission(submission, dashboard_url)
  end
end
