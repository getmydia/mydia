defmodule MetadataRelay.Feedback do
  @moduledoc """
  Stores and triages feedback submissions from Mydia instances.
  """

  import Ecto.Query

  alias MetadataRelay.Feedback.Submission
  alias MetadataRelay.GitHub.Client
  alias MetadataRelay.Repo

  def create_submission(attrs) when is_map(attrs) do
    %Submission{}
    |> Submission.changeset(attrs)
    |> Repo.insert()
  end

  def list_submissions(opts \\ []) do
    Submission
    |> maybe_filter(:state, Keyword.get(opts, :state))
    |> maybe_filter(:type, Keyword.get(opts, :type))
    |> order_by([submission], desc: submission.inserted_at)
    |> Repo.all()
  end

  def submission_summary do
    Repo.one(
      from(submission in Submission,
        select: %{
          total: count(submission.id),
          unread:
            fragment(
              "coalesce(sum(case when ? = 'unread' then 1 else 0 end), 0)",
              submission.state
            ),
          read:
            fragment(
              "coalesce(sum(case when ? = 'read' then 1 else 0 end), 0)",
              submission.state
            ),
          filed:
            fragment(
              "coalesce(sum(case when ? = 'filed' then 1 else 0 end), 0)",
              submission.state
            ),
          archived:
            fragment(
              "coalesce(sum(case when ? = 'archived' then 1 else 0 end), 0)",
              submission.state
            ),
          bug:
            fragment(
              "coalesce(sum(case when ? = 'bug' then 1 else 0 end), 0)",
              submission.type
            ),
          idea:
            fragment(
              "coalesce(sum(case when ? = 'idea' then 1 else 0 end), 0)",
              submission.type
            ),
          question:
            fragment(
              "coalesce(sum(case when ? = 'question' then 1 else 0 end), 0)",
              submission.type
            )
        }
      )
    )
  end

  def get_submission(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      Repo.get(Submission, uuid)
    else
      :error -> nil
    end
  end

  def get_submission!(id), do: Repo.get!(Submission, id)

  def update_state(%Submission{} = submission, state) do
    submission
    |> Submission.state_changeset(state)
    |> Repo.update()
  end

  def set_github_ref(%Submission{} = submission, github_ref) do
    submission
    |> Submission.github_ref_changeset(github_ref)
    |> Repo.update()
  end

  @doc """
  Creates a GitHub issue for a submission using the caller's token.

  On success the reference, URL, and state are written in one update. On
  failure the row is left untouched, so a failed call never leaves a
  half-filed submission behind.
  """
  def file_issue(%Submission{} = submission, attrs, token) do
    with {:ok, %{number: number, html_url: html_url}} <- Client.create_issue(attrs, token) do
      submission
      |> Submission.filed_changeset("##{number}", html_url)
      |> Repo.update()
    end
  end

  @doc """
  Base URL of the maintainer dashboard, with any trailing slash removed.

  Shared by the email notifier and the GitHub issue body so both derive their
  backlink from one place.
  """
  def dashboard_url do
    :metadata_relay
    |> Application.get_env(MetadataRelay.Feedback.Notifier, [])
    |> Keyword.get(:dashboard_url)
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> String.trim_trailing(trimmed, "/")
        end

      _ ->
        nil
    end
  end

  @doc """
  Dashboard link for a submission, focusing and anchoring it.

  The two-argument form takes the base URL so pure callers such as
  `MetadataRelay.Feedback.IssueDraft` can build the same link without reading
  configuration. This is the single definition of the link format.
  """
  def submission_url(submission), do: submission_url(submission, dashboard_url())

  def submission_url(_submission, nil), do: nil

  def submission_url(%Submission{id: id}, base) when is_binary(base) do
    "#{base}/feedback?focus=#{id}#feedback-#{id}"
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, "all"), do: query
  defp maybe_filter(query, _field, :all), do: query

  defp maybe_filter(query, field, value) do
    where(query, [submission], field(submission, ^field) == ^value)
  end
end
