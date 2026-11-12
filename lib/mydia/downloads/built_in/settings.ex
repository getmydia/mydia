defmodule Mydia.Downloads.BuiltIn.Settings do
  @moduledoc """
  The admin form's API for the built-in torrent client and its VPN.

  Values live in `config_settings` under `built_in_torrent.<field>` and are
  layered by `Mydia.Config.Loader`: an environment variable wins over a saved
  row, which wins over the default. A field whose variable is set is read-only:
  it is skipped by validation and never written.

  `save/2` follows `Mydia.Indexers.Cardigann.EngineSetting`: the writes and the
  config reload share one transaction, so a reload that fails leaves no row
  behind. It does not touch the running client; `BuiltIn.Manager` applies the
  reloaded config.

  Values are stored as the strings `Mydia.Config.Schema.Paths.cast_overlay/2`
  casts back: `"true"`/`"false"` and decimal integers. A blank text field
  deletes its row (back to the default), `enabled = "automatic"` deletes its
  row, and a blank secret keeps the stored value.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Mydia.Config.Loader
  alias Mydia.Config.Schema.BuiltInTorrent
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.Config
  alias Mydia.Downloads.BuiltIn.VpnProviders
  alias Mydia.Downloads.Download
  alias Mydia.Repo
  alias Mydia.Settings

  @env_vars BuiltInTorrent.env_vars()
  @fields Keyword.keys(@env_vars)
  @secret_fields BuiltInTorrent.secret_fields()

  @booleans [:vpn_enabled, :vpn_port_forwarding]
  @integers [:listen_port, :api_port]
  @enabled_choices ["automatic", "true", "false"]
  @text_fields @fields -- (@booleans ++ @integers ++ [:enabled])
  @identifier_fields [:vpn_provider, :vpn_type]

  # Providers whose OpenVPN login is not a username and password
  # (gluetun's `isUserRequired` in settings/openvpn.go).
  @no_login_providers ["airvpn", "vpnsecure"]

  @types (for field <- @fields, into: %{} do
            type =
              cond do
                field in @booleans -> :boolean
                field in @integers -> :integer
                true -> :string
              end

            {field, type}
          end)

  @type getenv :: (String.t() -> String.t() | nil)

  @doc "The form fields, in `BuiltInTorrent` order."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  Validates form params against the current layered section.

  Returns a changeset with action `:validate`. `current` supplies the values
  of fields the params leave out. Options: `:getenv`. Secret values are
  removed from the returned changeset, so rendering or inspecting it never
  exposes them.
  """
  @spec form_changeset(map(), BuiltInTorrent.t(), keyword()) :: Ecto.Changeset.t()
  def form_changeset(params, %BuiltInTorrent{} = current, opts \\ []) do
    params |> build_changeset(current, opts) |> redact_secrets()
  end

  defp build_changeset(params, current, opts) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)
    locked = locked_fields(getenv)

    params =
      params
      |> stringify_keys()
      |> Map.take(Enum.map(@fields -- locked, &Atom.to_string/1))
      |> drop_blank_secrets()

    {current_data(current), @types}
    |> cast(params, @fields -- locked)
    |> update_change_each(@identifier_fields, &normalize_identifier/1)
    |> validate_inclusion(:enabled, @enabled_choices)
    |> validate_number(:listen_port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> validate_number(:api_port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> validate_single_line(@text_fields -- locked)
    |> validate_vpn(locked)
    |> Map.put(:action, :validate)
  end

  @doc """
  Validates and saves form params, then reloads the runtime config.

  Options: `:getenv`, `:reload` (default `Loader.reload/0`), `:updated_by_id`,
  `:current` (the section to validate against, default the runtime config's).
  """
  @spec save(map(), keyword()) :: :ok | {:error, Ecto.Changeset.t()}
  def save(params, opts \\ []) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)
    reload = Keyword.get(opts, :reload, &Loader.reload/0)
    current = Keyword.get_lazy(opts, :current, &current_section/0)
    changeset = build_changeset(params, current, getenv: getenv)

    if changeset.valid? do
      persist(changeset, current, opts[:updated_by_id], reload)
    else
      {:error, redact_secrets(changeset)}
    end
  end

  @doc "Where each field's effective value comes from."
  @spec sources(getenv()) :: %{atom() => :env | :database | :default}
  def sources(getenv \\ &System.get_env/1) do
    applied = Settings.applied_config_settings_by_key()

    Map.new(@env_vars, fn {field, var} ->
      source =
        cond do
          Settings.env_var_set?(var, getenv) -> :env
          Map.has_key?(applied, setting_key(field)) -> :database
          true -> :default
        end

      {field, source}
    end)
  end

  @doc "Whether a non-blank value is saved for a secret field."
  @spec secret_saved?(atom()) :: boolean()
  def secret_saved?(field) when field in @secret_fields do
    case Settings.get_config_setting_by_key(setting_key(field)) do
      %{value: value} when is_binary(value) -> value != ""
      _ -> false
    end
  end

  @doc """
  Downloads the built-in client is still working on.

  Counts rows for the built-in client with no `completed_at` and still present
  in the client (`client_removed_at` is nil). Download status is derived from
  the client at runtime, so there is no failed or cancelled column to exclude.
  """
  @spec active_download_count() :: non_neg_integer()
  def active_download_count do
    name = BuiltIn.name()

    Repo.one(
      from d in Download,
        where: d.download_client == ^name and is_nil(d.completed_at),
        where: is_nil(d.client_removed_at),
        select: count(d.id)
    )
  end

  @doc """
  Why the client is off: `:name_taken` (another client holds the reserved
  name), `:env` (the environment variable), `:ui` (a saved choice) or
  `:automatic` (the default rule). Accepts a nil config. The second argument
  is a getenv function, or a map from `sources/1` already read by the caller.
  """
  @spec off_reason(Config.t() | nil, getenv() | map()) ::
          :env | :ui | :automatic | :name_taken
  def off_reason(config, getenv_or_sources \\ &System.get_env/1)

  def off_reason(config, getenv) when is_function(getenv, 1),
    do: off_reason(config, sources(getenv))

  def off_reason(%Config{warnings: warnings}, sources) when is_map(sources) do
    if {:reserved_name_taken} in warnings, do: :name_taken, else: source_reason(sources)
  end

  def off_reason(_config, sources) when is_map(sources), do: source_reason(sources)

  defp source_reason(sources) do
    case sources.enabled do
      :env -> :env
      :database -> :ui
      :default -> :automatic
    end
  end

  @doc """
  Whether saving `params` would stop work in progress or expose the server's
  address, so the form asks first. `running` is the config of the running
  client (nil when none runs, which makes nothing disruptive).

    * `{:disable, count}` when `enabled` resolves to off while `count`
      built-in downloads are active. `"false"` is off; `"automatic"` is
      resolved with `Config.from_runtime/4`'s rule against the running
      section, the configured clients and the environment.
    * `:vpn_off` when `vpn_enabled` is `"false"` and the VPN is on.

  Options (tests): `:clients` (`{types, name_taken?}` or `:unknown`, default
  `Manager.configured_clients/0`), `:env` (default `System.get_env/0`), and
  `:find_executable` / `:file_exists?`, passed to `Config.from_runtime/4`.
  """
  @spec disruptive_change(map(), Config.t() | nil, keyword()) ::
          nil | {:disable, pos_integer()} | :vpn_off
  def disruptive_change(params, running, opts \\ [])

  def disruptive_change(_params, nil, _opts), do: nil

  def disruptive_change(params, %Config{} = running, opts) do
    params = stringify_keys(params)

    cond do
      turns_off?(params["enabled"], running, opts) ->
        case active_download_count() do
          0 -> nil
          count -> {:disable, count}
        end

      params["vpn_enabled"] == "false" and running.vpn? ->
        :vpn_off

      true ->
        nil
    end
  end

  defp turns_off?("false", _running, _opts), do: true

  defp turns_off?("automatic", running, opts) do
    {types, _name_taken?} =
      case Keyword.get_lazy(opts, :clients, &BuiltIn.Manager.configured_clients/0) do
        :unknown -> {:unknown, false}
        summary -> summary
      end

    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    section = %{running.vpn_section | enabled: nil}
    config_opts = Keyword.take(opts, [:find_executable, :file_exists?])

    not Config.from_runtime(section, env, types, config_opts).enabled?
  end

  defp turns_off?(_enabled, _running, _opts), do: false

  ## Persistence

  defp persist(changeset, current, updated_by_id, reload) do
    ops = write_ops(changeset, current)

    result =
      Repo.transaction(fn ->
        with :ok <- apply_ops(ops, updated_by_id),
             {:ok, _config} <- reload.() do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        :ok

      {:error, _reason} ->
        # The reason can be a changeset or an error holding a submitted secret,
        # so it is never put into the message or logged.
        {:error,
         changeset
         |> add_error(:base, "The settings could not be saved. Nothing was changed.")
         |> redact_secrets()}
    end
  end

  # [{:put, key, value} | {:delete, key}] for changed fields only.
  defp write_ops(changeset, current) do
    existing = Settings.applied_config_settings_by_key()

    # Every submitted field, not only changed ones: a blank value must delete
    # a row even when the layered value it clears is already the default.
    submitted = Enum.filter(@fields, &Map.has_key?(changeset.params, Atom.to_string(&1)))

    for field <- submitted,
        op = op_for(field, get_field(changeset, field), existing, current),
        do: op
  end

  defp op_for(field, value, existing, current) do
    key = setting_key(field)
    row = Map.get(existing, key)

    case encode(field, value) do
      nil -> if row, do: {:delete, key}
      encoded -> put_op(key, encoded, row, field, value, current)
    end
  end

  defp put_op(key, encoded, nil, field, value, current) do
    # No row: skip a value the layered config already has.
    if Map.get(current, field) == value, do: nil, else: {:put, key, encoded}
  end

  defp put_op(key, encoded, %{value: stored}, _field, _value, _current) do
    if stored == encoded, do: nil, else: {:put, key, encoded}
  end

  defp encode(:enabled, "automatic"), do: nil
  defp encode(_field, nil), do: nil
  defp encode(_field, value) when is_boolean(value), do: to_string(value)
  defp encode(_field, value) when is_integer(value), do: Integer.to_string(value)

  defp encode(_field, value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp apply_ops(ops, updated_by_id) do
    Enum.reduce_while(ops, :ok, fn op, :ok ->
      case apply_op(op, updated_by_id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_op({:put, key, value}, updated_by_id) do
    attrs = %{key: key, value: value, category: :built_in_torrent, updated_by_id: updated_by_id}

    case Settings.upsert_config_setting(attrs) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp apply_op({:delete, key}, _updated_by_id) do
    case Settings.get_config_setting_by_key(key) do
      nil ->
        :ok

      row ->
        case Settings.delete_config_setting(row) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
    end
  end

  ## Changeset

  defp current_section, do: Settings.get_runtime_config().built_in_torrent

  # Stored secrets stay out of the changeset data; `require_value/3` asks
  # `secret_saved?/1` instead.
  defp current_data(current) do
    data = current |> Map.take(@fields) |> Map.merge(Map.new(@secret_fields, &{&1, nil}))
    %{data | enabled: enabled_choice(data.enabled)}
  end

  defp redact_secrets(changeset) do
    keys = Enum.map(@secret_fields, &Atom.to_string/1)

    %{
      changeset
      | changes: Map.drop(changeset.changes, @secret_fields),
        params: changeset.params && Map.drop(changeset.params, keys)
    }
  end

  defp enabled_choice(nil), do: "automatic"
  defp enabled_choice(value), do: to_string(value)

  defp stringify_keys(params), do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  # A blank or absent secret keeps the stored value.
  defp drop_blank_secrets(params) do
    Enum.reduce(@secret_fields, params, fn field, acc ->
      key = Atom.to_string(field)
      if blank?(Map.get(acc, key)), do: Map.delete(acc, key), else: acc
    end)
  end

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp update_change_each(changeset, fields, fun) do
    Enum.reduce(fields, changeset, &update_change(&2, &1, fun))
  end

  defp normalize_identifier(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_identifier(value), do: value

  defp validate_single_line(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case get_field(acc, field) do
        value when is_binary(value) ->
          if String.contains?(value, ["\n", "\r"]) do
            add_error(acc, field, "cannot contain a line break")
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp validate_vpn(changeset, locked) do
    provider = get_field(changeset, :vpn_provider)
    vpn? = get_field(changeset, :vpn_enabled) == true

    if vpn? or present?(provider) do
      info = VpnProviders.get(provider)

      changeset
      |> validate_provider(info, provider, locked)
      |> validate_type(info, locked)
      |> validate_port_forwarding(info, locked)
      |> validate_credentials(info, vpn?, locked)
    else
      changeset
    end
  end

  defp validate_provider(changeset, nil, provider, locked) do
    message = if present?(provider), do: "is not a supported provider", else: "can't be blank"
    error_unless_locked(changeset, :vpn_provider, message, locked)
  end

  defp validate_provider(changeset, _info, _provider, _locked), do: changeset

  defp validate_type(changeset, nil, _locked), do: changeset

  defp validate_type(changeset, info, locked) do
    type = get_field(changeset, :vpn_type)

    if present?(type) and type not in info.types do
      error_unless_locked(
        changeset,
        :vpn_type,
        "is not available for #{info.label} (use #{Enum.join(info.types, " or ")})",
        locked
      )
    else
      changeset
    end
  end

  defp validate_port_forwarding(changeset, nil, _locked), do: changeset

  defp validate_port_forwarding(changeset, info, locked) do
    if get_field(changeset, :vpn_port_forwarding) == true and not info.port_forwarding? do
      error_unless_locked(
        changeset,
        :vpn_port_forwarding,
        "is not supported by #{info.label}",
        locked
      )
    else
      changeset
    end
  end

  defp validate_credentials(changeset, _info, false, _locked), do: changeset
  defp validate_credentials(changeset, nil, _vpn?, _locked), do: changeset

  defp validate_credentials(changeset, info, true, locked) do
    type = get_field(changeset, :vpn_type)

    cond do
      type == "wireguard" ->
        changeset
        |> require_value(:vpn_wireguard_private_key, locked)
        |> require_value(:vpn_wireguard_addresses, locked)

      info.name in @no_login_providers ->
        changeset

      true ->
        changeset
        |> require_value(:vpn_openvpn_user, locked)
        |> require_value(:vpn_openvpn_password, locked)
    end
  end

  defp require_value(changeset, field, locked) do
    if present?(get_field(changeset, field)) or (field in @secret_fields and secret_saved?(field)) do
      changeset
    else
      error_unless_locked(changeset, field, "can't be blank", locked)
    end
  end

  defp error_unless_locked(changeset, field, message, locked) do
    if field in locked, do: changeset, else: add_error(changeset, field, message)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  ## Helpers

  defp locked_fields(getenv) do
    for {field, var} <- @env_vars, Settings.env_var_set?(var, getenv), do: field
  end

  defp setting_key(field), do: "built_in_torrent.#{field}"
end
