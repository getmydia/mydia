defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInEvents do
  @moduledoc """
  Assigns and events for the built-in torrent client's panel and settings
  modal, split out of `MydiaWeb.AdminDownloadClientsLive.Index` to keep that
  file readable. Validation and saving live in `Mydia.Downloads.BuiltIn.Settings`;
  this module only moves params and results between it and the socket.

  Secret values never land in an assign: the form keeps a typed secret in the
  browser, and only the submit carries it to `Settings.save/2`.
  """
  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, start_async: 3]

  alias Mydia.Config.Schema.BuiltInTorrent
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Manager, Preflight, Settings, Status}

  @events ~w(open_built_in_settings close_built_in_settings built_in_section validate_built_in
             save_built_in replace_built_in_secret enable_built_in)

  @secret_fields BuiltInTorrent.secret_fields()
  @secret_keys Enum.map(@secret_fields, &Atom.to_string/1)
  @sections %{"torrent" => :torrent, "vpn" => :vpn}
  @torrent_fields [:enabled, :download_path, :listen_port, :state_path, :api_port]
  # Values a segmented control sends as a click rather than a form change.
  @choice_keys ["enabled", "vpn_type"]

  @doc "The events `handle_event/3` answers."
  def events, do: @events

  @doc "Subscribes to status broadcasts and fills the panel assigns."
  def mount(socket) do
    # Subscribed whether or not the client runs, so turning it on shows its
    # progress live.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, Status.topic())
    end

    socket
    |> assign(:show_built_in_settings, false)
    |> refresh()
  end

  @doc "Re-reads whether the client runs, its status and, when off, why."
  def refresh(socket, status \\ :fetch) do
    runtime = BuiltIn.runtime()
    sources = Settings.sources(&System.get_env/1)

    status =
      cond do
        is_nil(runtime) -> nil
        status == :fetch -> safe_status()
        true -> status
      end

    socket
    |> assign(:built_in?, runtime != nil)
    |> assign(:built_in_vpn?, runtime != nil and runtime.config.vpn?)
    |> assign(:built_in_status, status)
    |> assign(:built_in_enable_locked?, sources.enabled == :env)
    |> assign(:built_in_off_reason, off_reason(runtime))
  end

  @doc "Applies a status broadcast."
  def put_status(socket, status), do: refresh(socket, status)

  def handle_event("open_built_in_settings", _params, socket) do
    manager_config = safe_current()
    gluetun_dir = (manager_config && manager_config.gluetun_dir) || %Config{}.gluetun_dir

    socket
    |> assign(:show_built_in_settings, true)
    |> assign(:built_in_section, :torrent)
    |> assign(:built_in_params, %{})
    |> assign(:built_in_sources, Settings.sources(&System.get_env/1))
    |> assign(:built_in_saved_secrets, Map.new(@secret_fields, &{&1, Settings.secret_saved?(&1)}))
    |> assign(:built_in_replacing, [])
    |> assign(:built_in_typed_secrets, [])
    |> assign(:built_in_confirm, nil)
    |> assign(:built_in_preflight, Preflight.read(gluetun_dir))
    |> assign(:built_in_env_vpn_names, (manager_config && manager_config.env_vpn_names) || [])
    |> assign_form(%{})
  end

  def handle_event("close_built_in_settings", _params, socket) do
    socket
    |> assign(:show_built_in_settings, false)
    |> assign(:built_in_confirm, nil)
  end

  def handle_event("built_in_section", %{"section" => section}, socket) do
    case Map.fetch(@sections, section) do
      {:ok, section} -> assign(socket, :built_in_section, section)
      :error -> socket
    end
  end

  # A form change carries every rendered input, typed secrets included.
  def handle_event("validate_built_in", %{"built_in" => params}, socket) do
    params = Map.merge(socket.assigns.built_in_params, params)

    socket
    |> assign(:built_in_typed_secrets, typed_secrets(params))
    |> assign(:built_in_confirm, nil)
    |> assign_form(params)
  end

  # A segmented control click carries only its own value.
  def handle_event("validate_built_in", params, socket) do
    params = Map.merge(socket.assigns.built_in_params, Map.take(params, @choice_keys))

    socket
    |> assign(:built_in_confirm, nil)
    |> assign_form(params)
  end

  def handle_event("save_built_in", %{"built_in" => params}, socket) do
    params = Map.merge(socket.assigns.built_in_params, params)
    confirm = confirmation(params)

    if confirm != nil and confirm != socket.assigns.built_in_confirm do
      assign(socket, :built_in_confirm, confirm)
    else
      save(socket, params)
    end
  end

  def handle_event("replace_built_in_secret", %{"field" => field}, socket) do
    case Enum.find(@secret_fields, &(Atom.to_string(&1) == field)) do
      nil -> socket
      field -> assign(socket, :built_in_replacing, [field | socket.assigns.built_in_replacing])
    end
  end

  def handle_event("enable_built_in", _params, socket) do
    case Settings.save(%{"enabled" => "true"}, updated_by_id: user_id(socket)) do
      :ok ->
        socket
        |> put_flash(:info, gettext("Turning on the built-in torrent client"))
        |> start_applied()

      {:error, _changeset} ->
        put_flash(
          socket,
          :error,
          gettext(
            "The built-in torrent client could not be turned on. Open Configure to check its settings."
          )
        )
    end
  end

  ## Private

  defp save(socket, params) do
    case Settings.save(params, updated_by_id: user_id(socket)) do
      :ok ->
        socket
        |> assign(:show_built_in_settings, false)
        |> assign(:built_in_confirm, nil)
        |> put_flash(:info, gettext("Built-in torrent client settings saved. Applying them now."))
        |> start_applied()

      {:error, changeset} ->
        socket
        |> assign(:built_in_confirm, nil)
        |> assign(:built_in_section, error_section(changeset, socket.assigns.built_in_section))
        |> assign(:built_in_typed_secrets, typed_secrets(params))
        |> assign(:built_in_params, Map.drop(params, @secret_keys))
        |> assign(:built_in_form, to_form(changeset, as: :built_in))
    end
  end

  # The form keeps the merged params without secrets, so a later click on a
  # segmented control can re-validate everything else.
  defp assign_form(socket, params) do
    changeset = Settings.form_changeset(params, current_section())

    socket
    |> assign(:built_in_params, Map.drop(params, @secret_keys))
    |> assign(:built_in_form, to_form(changeset, as: :built_in))
  end

  # Asks before stopping work in progress or exposing the server's address.
  defp confirmation(params) do
    runtime = BuiltIn.runtime()

    cond do
      is_nil(runtime) ->
        nil

      params["enabled"] == "false" ->
        case Settings.active_download_count() do
          0 -> nil
          count -> {:disable, count}
        end

      params["vpn_enabled"] == "false" and runtime.config.vpn? ->
        :vpn_off

      true ->
        nil
    end
  end

  # Shows the section holding the first field error, so a failed save never
  # leaves its message in the hidden section.
  defp error_section(changeset, section) do
    case Enum.find(changeset.errors, fn {field, _} -> field != :base end) do
      nil -> section
      {field, _} when field in @torrent_fields -> :torrent
      _ -> :vpn
    end
  end

  defp typed_secrets(params) do
    Enum.filter(@secret_fields, fn field ->
      value = params[Atom.to_string(field)]
      is_binary(value) and String.trim(value) != ""
    end)
  end

  # The manager handles the reload before this call, so the reply comes after
  # the save has been applied. Disabling sends no status broadcast, so this is
  # what updates the panel then.
  defp start_applied(socket), do: start_async(socket, :built_in_applied, &safe_await_applied/0)

  defp off_reason(nil), do: Settings.off_reason(nil, &System.get_env/1)
  defp off_reason(_runtime), do: nil

  defp current_section, do: Mydia.Settings.get_runtime_config().built_in_torrent

  defp user_id(socket), do: socket.assigns.current_user.id

  # Reads the last evaluated config without calling the manager, so it never
  # waits on an apply. Nil where the manager is absent (tests, some installs).
  defp safe_current, do: Manager.current()

  defp safe_await_applied do
    Manager.await_applied()
  catch
    :exit, _ -> nil
  end

  # nil when the Status process cannot be read: the panel then says the status
  # is unavailable rather than showing a made-up state. The next broadcast
  # fills it in.
  defp safe_status do
    Status.get()
  catch
    :exit, _ -> nil
  end
end
