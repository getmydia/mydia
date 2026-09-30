defmodule Mydia.Plugins.Setup do
  @moduledoc """
  Drives a plugin's declarative setup screens (contract 1.5 `setup` export).

  The host owns the wizard: it keeps the session, validates what it can before
  calling the guest, applies what a screen carries (credentials, approved
  endpoints, account links) and renders the next screen. The guest only decides
  which screen comes next.

  Starting without an instance creates a disabled draft, so every guest call
  has an instance id to key its store and links on. A `done` screen enables
  the draft; `cancel/1` deletes it. On an existing instance, `cancel/1`
  withdraws only the endpoints the session approved.

  Guest calls never run inside a database transaction.
  """

  alias Mydia.Accounts
  alias Mydia.Accounts.UsernameIndex
  alias Mydia.Plugins
  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Setup.Session
  alias Mydia.Settings

  require Logger

  @spec start(String.t(), Instance.t() | nil, keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def start(slug, instance, opts \\ [])

  def start(slug, nil, opts) when is_binary(slug) do
    name = Keyword.get(opts, :name) || plugin_name(slug)

    with {:ok, instance} <- Instances.create(slug, %{name: name, enabled: false}) do
      %Session{slug: slug, instance_id: instance.id, new_instance?: true}
      |> call(Keyword.get(opts, :step, "start"), %{})
    end
  end

  def start(slug, %Instance{plugin_slug: slug} = instance, opts) do
    %Session{slug: slug, instance_id: instance.id}
    |> call(Keyword.get(opts, :step, "start"), %{})
  end

  @spec advance(Session.t(), map()) :: {:ok, Session.t()}
  def advance(%Session{status: :active, screen: %{step: step, body: body}} = session, input)
      when is_map(input) do
    case prepare(session, body, input) do
      {:ok, session, guest_input} -> call(session, step, guest_input)
      {:error, message} -> {:ok, %{session | error: message}}
    end
  end

  def advance(%Session{} = session, _input),
    do: {:ok, %{session | error: "Setup is not waiting for an answer."}}

  @spec poll(Session.t()) :: {:ok, Session.t()}
  def poll(%Session{status: :active, screen: %{body: {:external_auth, _}}} = session),
    do: call(session, "poll", %{})

  def poll(%Session{} = session), do: {:ok, session}

  @spec cancel(Session.t()) :: :ok
  def cancel(%Session{status: :done}), do: :ok

  def cancel(%Session{new_instance?: true, instance_id: id}) do
    case Instances.get(id) do
      nil -> :ok
      instance -> Instances.delete(instance)
    end
  end

  def cancel(%Session{instance_id: id, pending_endpoints: pending}) do
    case Instances.get(id) do
      nil ->
        :ok

      instance ->
        _ =
          Enum.reduce(pending, instance, fn endpoint, acc ->
            {:ok, acc} = Instances.remove_endpoint(acc, endpoint)
            acc
          end)

        :ok
    end
  end

  @doc """
  Turns an operator-typed URL into an approved-endpoint map, filling the
  scheme's default port. Only http and https are accepted.
  """
  @spec endpoint_from_url(String.t()) :: {:ok, map()} | :error
  def endpoint_from_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, %{"scheme" => scheme, "host" => String.downcase(host), "port" => port}}

      _ ->
        :error
    end
  end

  @doc """
  Fills in what the guest cannot know on a mapping screen: which Mydia user
  each remote account probably belongs to.

  Per account, the first rule that yields a user not already suggested for
  another account wins: the guest's own suggestion, the instance's existing
  link for that account, a case-insensitive username match, and for an admin
  account the sole Mydia admin when there is exactly one. An empty account
  list is filled from the accounts the plugin proposed for this instance.
  """
  @spec enrich_mapping(map(), binary()) :: map()
  def enrich_mapping(%{accounts: accounts, suggestions: suggestions} = mapping, instance_id) do
    accounts = if accounts == [], do: proposed_accounts(instance_id), else: accounts

    guest = Map.new(suggestions, &{&1.remote_account_id, &1.user_id})

    linked =
      instance_id
      |> AccountLinks.list()
      |> Enum.filter(&(&1.role == :user and &1.user_id != nil))
      |> Map.new(&{&1.external_user_id, &1.user_id})

    index = UsernameIndex.build(Accounts.list_users())

    sole_admin =
      case Accounts.list_users(role: "admin") do
        [admin] -> admin.id
        _ -> nil
      end

    candidates = fn account ->
      [
        guest[account.id],
        linked[account.id],
        case UsernameIndex.get(index, account.name) do
          nil -> nil
          user -> user.id
        end,
        if(account.admin, do: sole_admin)
      ]
    end

    {suggested, _taken} =
      Enum.reduce(accounts, {[], MapSet.new()}, fn account, {acc, taken} ->
        case Enum.find(candidates.(account), &(&1 != nil and not MapSet.member?(taken, &1))) do
          nil ->
            {acc, taken}

          user_id ->
            {[%{remote_account_id: account.id, user_id: user_id} | acc],
             MapSet.put(taken, user_id)}
        end
      end)

    %{mapping | accounts: accounts, suggestions: Enum.reverse(suggested)}
  end

  defp proposed_accounts(instance_id) do
    case Instances.get(instance_id) do
      nil ->
        []

      instance ->
        Enum.map(instance.remote_accounts, fn account ->
          %{id: account["id"], name: account["name"], admin: account["admin"] == true}
        end)
    end
  end

  ## Screen answers

  defp prepare(_session, {:external_auth, _}, _input),
    do: {:error, "Waiting for sign-in to finish."}

  defp prepare(_session, {:done, _}, _input), do: {:error, "Setup is already finished."}

  defp prepare(session, {:choice, %{options: options}}, input) do
    case Enum.find(options, &(&1.id == input["option_id"])) do
      nil ->
        {:error, "Choose one of the options."}

      option ->
        with {:ok, session} <- approve(session, option.endpoints) do
          {:ok, store_credentials(session, option.credentials), %{"option_id" => option.id}}
        end
    end
  end

  defp prepare(session, {:form, %{fields: fields}}, input) do
    values = Map.new(fields, fn field -> {field.key, to_string(input[field.key] || "")} end)

    case Enum.find(fields, &(&1.required and String.trim(values[&1.key]) == "")) do
      nil ->
        with {:ok, session} <- approve(session, url_endpoints(fields, values)) do
          {:ok, persist_declared_settings(session, values), values}
        end

      field ->
        {:error, "#{field.label} is required."}
    end
  end

  defp prepare(session, {:mapping, %{accounts: accounts}}, input) do
    mapping = input["mapping"] || %{}

    entries =
      for account <- accounts,
          user_id = mapping[account.id],
          user_id not in [nil, ""] do
        %{remote_account_id: account.id, remote_username: account.name, user_id: user_id}
      end

    user_ids = Enum.map(entries, & &1.user_id)

    if length(user_ids) != length(Enum.uniq(user_ids)) do
      {:error, "Each Mydia user can be linked to one account."}
    else
      case AccountLinks.replace_user_links(session.instance_id, entries, :admin_mapped) do
        {:ok, links} ->
          {:ok, session, %{"links" => Enum.map(links, &link_input/1)}}

        {:error, reason} ->
          Logger.warning("plugin setup could not save account links: #{inspect(reason)}")
          {:error, "The account links could not be saved."}
      end
    end
  end

  defp link_input(link) do
    %{
      "link_id" => link.id,
      "remote_account_id" => link.external_user_id,
      "user_id" => link.user_id
    }
  end

  ## Guest calls

  defp call(%Session{} = session, step, input) do
    request = %{step: step, input_json: Jason.encode!(input), state_json: session.state_json}

    case Plugins.invoke_setup(session.slug, session.instance_id, request) do
      {:ok, screen} ->
        {:ok, receive_screen(session, screen)}

      {:error, error} ->
        Logger.warning("plugin #{session.slug} setup step #{step} failed: #{error.type}")
        {:ok, %{session | error: error_message(error)}}
    end
  end

  defp receive_screen(session, %{body: {:mapping, mapping}} = screen) do
    screen = %{screen | body: {:mapping, enrich_mapping(mapping, session.instance_id)}}
    do_receive_screen(session, screen)
  end

  defp receive_screen(session, screen), do: do_receive_screen(session, screen)

  defp do_receive_screen(session, screen) do
    session =
      session
      |> store_credentials(screen.credentials)
      |> Map.merge(%{
        step: screen.step,
        # Persisted above; the session (kept in LiveView assigns) holds none.
        screen: %{screen | credentials: []},
        state_json: screen.next_state_json,
        error: screen.error
      })

    case screen.body do
      {:done, _} -> finish(session)
      _ -> session
    end
  end

  defp finish(%Session{new_instance?: true} = session) do
    {:ok, _} = session.instance_id |> Instances.get!() |> Instances.update(%{enabled: true})
    %{session | status: :done}
  end

  defp finish(session), do: %{session | status: :done}

  ## Side effects of an answer

  defp store_credentials(session, credentials) do
    Enum.each(credentials, fn
      %{role: role, token: token} when role in [:owner, :endpoint] and token != "" ->
        {:ok, _} = AccountLinks.put_credential(session.instance_id, role, token)

      %{role: role} ->
        Logger.warning(
          "plugin #{session.slug} setup returned an unusable credential role #{role}"
        )
    end)

    session
  end

  defp approve(session, []), do: {:ok, session}

  defp approve(session, endpoints) do
    instance = Instances.get!(session.instance_id)
    wanted = Enum.map(endpoints, &stringify_endpoint/1)
    new = Enum.reject(wanted, &(&1 in instance.approved_endpoints))

    case Instances.approve_endpoints(instance, wanted) do
      {:ok, _} ->
        {:ok, %{session | pending_endpoints: Enum.uniq(session.pending_endpoints ++ new)}}

      {:error, {:invalid_endpoint, endpoint}} ->
        {:error,
         "The server address #{describe_endpoint(endpoint)} is not valid. " <>
           "Use a full http:// or https:// address with a port between 1 and 65535."}

      {:error, _changeset} ->
        {:error, "The server address could not be saved."}
    end
  end

  defp describe_endpoint(%{"scheme" => scheme, "host" => host, "port" => port}),
    do: "#{scheme}://#{host}:#{port || "?"}"

  defp stringify_endpoint(%{scheme: scheme, host: host, port: port}),
    do: %{
      "scheme" => scheme,
      "host" => host |> to_string() |> String.downcase(),
      "port" => port
    }

  defp stringify_endpoint(%{"scheme" => _, "host" => _, "port" => _} = endpoint), do: endpoint

  defp url_endpoints(fields, values) do
    for %{field_type: "url", key: key} <- fields,
        {:ok, endpoint} <- [endpoint_from_url(values[key])],
        do: endpoint
  end

  defp persist_declared_settings(session, values) do
    declared = declared_setting_keys(session.slug)
    settings = Map.take(values, declared) |> Map.reject(fn {_k, v} -> v == "" end)

    if settings != %{} do
      instance = Instances.get!(session.instance_id)
      {:ok, _} = Instances.update(instance, %{settings: Map.merge(instance.settings, settings)})
    end

    session
  end

  defp declared_setting_keys(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      %{manifest: %{"settings_schema" => schema}} when is_list(schema) ->
        Enum.flat_map(schema, fn
          %{"key" => key} -> [key]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp plugin_name(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      %{name: name} when is_binary(name) -> name
      _ -> slug
    end
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(other), do: inspect(other)
end
