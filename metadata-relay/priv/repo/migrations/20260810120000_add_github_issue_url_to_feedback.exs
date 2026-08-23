defmodule MetadataRelay.Repo.Migrations.AddGithubIssueUrlToFeedback do
  use Ecto.Migration

  def change do
    alter table(:feedback_submissions) do
      add(:github_issue_url, :string)
    end
  end
end
