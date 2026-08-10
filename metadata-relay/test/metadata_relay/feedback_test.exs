defmodule MetadataRelay.FeedbackTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias MetadataRelay.Feedback
  alias MetadataRelay.Feedback.Submission
  alias MetadataRelay.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Submission)
    :ok
  end

  test "create_submission/1 stores a required feedback submission" do
    assert {:ok, %Submission{} = submission} =
             Feedback.create_submission(%{type: "bug", message: "Something broke"})

    assert submission.state == "unread"
    assert submission.type == "bug"
    assert submission.message == "Something broke"
  end

  test "create_submission/1 accepts optional fields" do
    attrs = %{
      type: "idea",
      message: "Add watch party mode",
      contact: "user@example.com",
      instance_id: "instance-123",
      mydia_version: "1.2.3-dev",
      source_ip: "203.0.113.10"
    }

    assert {:ok, submission} = Feedback.create_submission(attrs)
    assert submission.contact == "user@example.com"
    assert submission.instance_id == "instance-123"
    assert submission.mydia_version == "1.2.3-dev"
    assert submission.source_ip == "203.0.113.10"
  end

  test "create_submission/1 accepts nil instance_id" do
    assert {:ok, submission} =
             Feedback.create_submission(%{type: "question", message: "How?", instance_id: nil})

    assert submission.instance_id == nil
  end

  test "create_submission/1 rejects invalid type" do
    assert {:error, changeset} = Feedback.create_submission(%{type: "spam", message: "Buy now"})
    assert {"is invalid", _} = changeset.errors[:type]
  end

  test "create_submission/1 rejects empty message" do
    assert {:error, changeset} = Feedback.create_submission(%{type: "bug", message: ""})
    assert {"can't be blank", _} = changeset.errors[:message]
  end

  test "list_submissions/1 filters by state and orders newest first" do
    {:ok, old} = Feedback.create_submission(%{type: "bug", message: "Old"})
    {:ok, archived} = Feedback.create_submission(%{type: "idea", message: "Archived"})
    {:ok, new} = Feedback.create_submission(%{type: "question", message: "New"})

    Repo.update_all(from(s in Submission, where: s.id == ^old.id),
      set: [inserted_at: ~U[2026-01-01 00:00:00Z]]
    )

    Repo.update_all(from(s in Submission, where: s.id == ^new.id),
      set: [inserted_at: ~U[2026-01-02 00:00:00Z]]
    )

    {:ok, _archived} = Feedback.update_state(archived, "archived")

    assert [new.id, old.id] == Feedback.list_submissions(state: "unread") |> Enum.map(& &1.id)
  end

  test "list_submissions/1 filters by type" do
    {:ok, bug} = Feedback.create_submission(%{type: "bug", message: "Bug"})
    {:ok, _idea} = Feedback.create_submission(%{type: "idea", message: "Idea"})

    assert [^bug] = Feedback.list_submissions(type: "bug")
  end

  test "update_state/2 transitions state" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Bug"})

    assert {:ok, updated} = Feedback.update_state(submission, "archived")
    assert updated.state == "archived"
  end

  test "set_github_ref/2 persists the triage tag" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Bug"})

    assert {:ok, updated} = Feedback.set_github_ref(submission, "gh#123")
    assert updated.github_ref == "gh#123"
  end

  test "update_state/2 rejects invalid state" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Bug"})

    assert {:error, changeset} = Feedback.update_state(submission, "invalid")
    assert {"is invalid", _} = changeset.errors[:state]
  end

  test "summary counts filed submissions" do
    {:ok, filed} = Feedback.create_submission(%{type: "bug", message: "Filed"})
    {:ok, _filed} = Feedback.update_state(filed, "filed")

    assert %{filed: 1} = Feedback.submission_summary()
  end

  test "saving a github ref promotes unread to filed" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Unread"})

    {:ok, updated} = Feedback.set_github_ref(submission, "#123")

    assert updated.state == "filed"
    assert updated.github_ref == "#123"
  end

  test "saving a github ref promotes read to filed" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Read"})
    {:ok, submission} = Feedback.update_state(submission, "read")

    {:ok, updated} = Feedback.set_github_ref(submission, "#123")

    assert updated.state == "filed"
  end

  test "saving a github ref leaves an archived submission archived" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Archived"})
    {:ok, submission} = Feedback.update_state(submission, "archived")

    {:ok, updated} = Feedback.set_github_ref(submission, "#123")

    assert updated.state == "archived"
  end

  test "clearing a github ref does not demote the state" do
    {:ok, submission} = Feedback.create_submission(%{type: "bug", message: "Filed"})
    {:ok, submission} = Feedback.set_github_ref(submission, "#123")

    {:ok, updated} = Feedback.set_github_ref(submission, nil)

    assert updated.state == "filed"
    assert updated.github_ref == nil
  end
end
