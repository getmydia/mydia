defmodule MetadataRelay.Feedback.Submission do
  @moduledoc """
  Persisted in-app feedback sent from Mydia instances.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ["bug", "idea", "question"]
  @states ["unread", "read", "filed", "archived"]
  @promotable_states ["unread", "read"]

  schema "feedback_submissions" do
    field(:type, :string)
    field(:message, :string)
    field(:contact, :string)
    field(:instance_id, :string)
    field(:mydia_version, :string)
    field(:source_ip, :string)
    field(:state, :string, default: "unread")
    field(:github_ref, :string)
    field(:github_issue_url, :string)

    timestamps(type: :utc_datetime)
  end

  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [
      :type,
      :message,
      :contact,
      :instance_id,
      :mydia_version,
      :source_ip,
      :state,
      :github_ref,
      :github_issue_url
    ])
    |> validate_required([:type, :message])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:state, @states)
  end

  def state_changeset(submission, state) do
    submission
    |> cast(%{state: state}, [:state])
    |> validate_required([:state])
    |> validate_inclusion(:state, @states)
  end

  def github_ref_changeset(submission, github_ref) do
    submission
    |> cast(%{github_ref: github_ref}, [:github_ref])
    |> maybe_promote_state()
    |> validate_inclusion(:state, @states)
  end

  def filed_changeset(submission, github_ref, github_issue_url) do
    state = if submission.state == "archived", do: "archived", else: "filed"

    submission
    |> cast(
      %{github_ref: github_ref, github_issue_url: github_issue_url, state: state},
      [:github_ref, :github_issue_url, :state]
    )
    |> validate_required([:github_ref, :state])
    |> validate_inclusion(:state, @states)
  end

  defp maybe_promote_state(changeset) do
    ref = get_field(changeset, :github_ref)
    state = changeset.data.state

    if present?(ref) and state in @promotable_states do
      put_change(changeset, :state, "filed")
    else
      changeset
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
