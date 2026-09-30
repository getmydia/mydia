defmodule Mydia.Plugins.Grants do
  @moduledoc """
  Standing permissions for plugin page writes, per user, plugin and write
  surface.

  A user answers a write confirmation with **once**, **session** or **always**.
  `once` records nothing; `session` holds for one page session id; `always`
  holds until revoked. An admin caps the scope each role may hold per plugin
  (`plugin_configs.role_ceilings`); a stored grant above the current ceiling
  stops counting, so lowering a ceiling takes effect immediately.
  """

  import Ecto.Query

  alias Mydia.Accounts
  alias Mydia.Plugins.WriteGrant
  alias Mydia.Repo
  alias Mydia.Settings

  @ranks %{"none" => 0, "once" => 1, "session" => 2, "always" => 3}
  @choices ~w(once session always)
  @roles ~w(admin user guest readonly)
  @default_ceilings %{
    "admin" => "always",
    "user" => "always",
    "guest" => "session",
    "readonly" => "none"
  }

  @doc "The highest grant scope `role` may hold for plugin `slug`."
  @spec ceiling(String.t(), String.t()) :: String.t()
  def ceiling(slug, role) do
    ceilings =
      case Settings.get_plugin_config_by_slug(slug) do
        %{role_ceilings: %{} = stored} -> Map.merge(@default_ceilings, stored)
        _ -> @default_ceilings
      end

    Map.get(ceilings, role, "none")
  end

  @doc "The confirmation choices `role` may pick for plugin `slug`, lowest first."
  @spec allowed_choices(String.t(), String.t()) :: [String.t()]
  def allowed_choices(slug, role) do
    max = rank(ceiling(slug, role))
    Enum.filter(@choices, &(rank(&1) <= max))
  end

  @doc "True when a grant lets `slug` write `surface` for the user in this session."
  @spec granted?(String.t(), binary(), String.t(), String.t()) :: boolean()
  def granted?(slug, user_id, surface, session_id) do
    case Accounts.get_user_by_id(user_id) do
      %{role: role} ->
        max = rank(ceiling(slug, role))

        WriteGrant
        |> where([g], g.plugin_slug == ^slug and g.user_id == ^user_id and g.surface == ^surface)
        |> where(
          [g],
          g.scope == "always" or (g.scope == "session" and g.session_id == ^session_id)
        )
        |> select([g], g.scope)
        |> Repo.all()
        |> Enum.any?(&(rank(&1) <= max))

      _ ->
        false
    end
  end

  @doc """
  Records the user's answer to a confirmation. `"once"` records nothing.
  Re-granting an existing scope is a no-op.
  """
  @spec grant(String.t(), binary(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def grant(_slug, _user_id, _surface, "once", _session_id), do: :ok

  def grant(slug, user_id, surface, scope, session_id) when scope in ["session", "always"] do
    attrs = %{
      plugin_slug: slug,
      user_id: user_id,
      surface: surface,
      scope: scope,
      session_id: if(scope == "always", do: "", else: session_id)
    }

    %WriteGrant{}
    |> WriteGrant.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  def grant(_slug, _user_id, _surface, _scope, _session_id), do: {:error, :invalid_scope}

  # An unknown scope ranks as none, so a malformed stored ceiling grants
  # nothing rather than everything.
  defp rank(scope), do: Map.get(@ranks, scope, 0)

  @doc """
  A user's standing (`always`) grants across all plugins, newest first.
  Session grants are left out: they end with the page session that made them.
  """
  @spec list_for_user(binary()) :: [WriteGrant.t()]
  def list_for_user(user_id) do
    WriteGrant
    |> where([g], g.user_id == ^user_id and g.scope == "always")
    |> order_by([g], desc: g.inserted_at)
    |> Repo.all()
  end

  @doc """
  Deletes the user's session grants for `slug` that belong to any page session
  other than `session_id`. Those sessions are over, so the rows can never apply
  again.
  """
  @spec prune_sessions(binary(), String.t(), String.t()) :: :ok
  def prune_sessions(user_id, slug, session_id) do
    Repo.delete_all(
      from g in WriteGrant,
        where:
          g.user_id == ^user_id and g.plugin_slug == ^slug and g.scope == "session" and
            g.session_id != ^session_id
    )

    :ok
  end

  @doc """
  Deletes every grant and pending write held for `slug`. Called when a plugin is
  removed so a plugin installed later under the same slug inherits no approvals.
  """
  @spec purge(String.t()) :: :ok
  def purge(slug) do
    Repo.delete_all(from g in WriteGrant, where: g.plugin_slug == ^slug)
    Repo.delete_all(from p in Mydia.Plugins.PendingWrite, where: p.plugin_slug == ^slug)
    :ok
  end

  @doc "Deletes one of the user's own grants."
  @spec revoke(binary(), binary()) :: :ok | {:error, :not_found}
  def revoke(user_id, grant_id) do
    case Repo.get_by(WriteGrant, id: grant_id, user_id: user_id) do
      nil -> {:error, :not_found}
      grant -> with {:ok, _} <- Repo.delete(grant), do: :ok
    end
  end

  @doc "Stores admin-set ceilings, merged over the current ones."
  @spec put_ceilings(String.t(), map()) ::
          {:ok, Settings.PluginConfig.t()} | {:error, term()}
  def put_ceilings(slug, ceilings) when is_map(ceilings) do
    with :ok <- validate_ceilings(ceilings),
         %{} = config <- Settings.get_plugin_config_by_slug(slug) || {:error, :not_found} do
      merged = Map.merge(config.role_ceilings || %{}, ceilings)
      Settings.update_plugin_config(config, %{role_ceilings: merged})
    end
  end

  defp validate_ceilings(ceilings) do
    if Enum.all?(ceilings, fn {role, scope} -> role in @roles and Map.has_key?(@ranks, scope) end),
       do: :ok,
       else: {:error, :invalid_ceilings}
  end
end
