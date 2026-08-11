defmodule Mydia.Integrations do
  @moduledoc """
  Context for managing external service integrations linked to a user.

  Provider-specific integrations now ship as plugins; see `Mydia.Plugins.Connections`.
  This context retains the generic `user_integrations` CRUD for future built-in providers.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Integrations.UserIntegration

  # ── CRUD ──────────────────────────────────────────────────────────────

  @doc """
  Gets a user integration by user_id and provider.
  Returns nil if not found.
  """
  def get_user_integration(user_id, provider) do
    Repo.get_by(UserIntegration, user_id: user_id, provider: provider)
  end

  @doc """
  Gets a user integration by ID.
  """
  def get_user_integration!(id) do
    Repo.get!(UserIntegration, id)
  end

  @doc """
  Lists all integrations for a user.
  """
  def list_user_integrations(user_id) do
    from(i in UserIntegration, where: i.user_id == ^user_id)
    |> Repo.all()
  end

  @doc """
  Creates a user integration.
  `user_id` is set explicitly (not via cast) for security.
  """
  def create_user_integration(user_id, attrs) do
    %UserIntegration{user_id: user_id}
    |> UserIntegration.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :user_id, :inserted_at]},
      conflict_target: [:user_id, :provider]
    )
  end

  @doc """
  Updates an existing user integration.
  """
  def update_user_integration(%UserIntegration{} = integration, attrs) do
    integration
    |> UserIntegration.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a user integration.
  """
  def delete_user_integration(%UserIntegration{} = integration) do
    Repo.delete(integration)
  end

  @doc """
  Lists integrations with tokens expiring within the given number of days.
  """
  def list_integrations_needing_refresh(days \\ 7) do
    cutoff = DateTime.utc_now() |> DateTime.add(days * 86_400, :second)

    from(i in UserIntegration,
      where:
        i.enabled == true and
          not is_nil(i.token_expires_at) and
          i.token_expires_at < ^cutoff
    )
    |> Repo.all()
  end
end
