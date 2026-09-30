defmodule MydiaWeb.PluginSetupLive.Modal do
  @moduledoc """
  Renders a plugin's setup screens (contract 1.4) in a modal.

  Every `Mydia.Plugins.Setup` call runs through `start_async`, so a slow guest
  step never blocks the page. An external sign-in screen is polled from the
  server with `send_update_after/4`; the `ExternalAuthPopup` hook only opens the
  window and reports when the operator closes it.

  When the modal closes it sends the parent
  `{#{inspect(__MODULE__)}, :closed, %{id:, status: :done | :cancelled, instance_id:}}`.
  """

  use MydiaWeb, :live_component

  import MydiaWeb.PluginSetupComponents

  alias Mydia.Accounts
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Setup
  alias Mydia.Plugins.Setup.Session

  @impl true
  def update(%{poll: true} = assigns, socket) do
    case socket.assigns do
      %{loading: false, session: %Session{screen: %{body: {:external_auth, _}}} = session} = a ->
        # A scheduled poll carries the generation it was scheduled in; a newer
        # chain (for example after the popup closed) makes older timers no-ops.
        if Map.get(assigns, :gen, a.poll_gen) == a.poll_gen,
          do: {:ok, run(socket, fn -> Setup.poll(session) end)},
          else: {:ok, socket}

      _ ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.take(assigns, [:id, :slug, :instance_id, :entry_step, :title]))
      |> assign_new(:instance_id, fn -> nil end)
      |> assign_new(:entry_step, fn -> "start" end)
      |> assign_new(:title, fn -> "Set up" end)

    if socket.assigns[:started] do
      {:ok, socket}
    else
      socket =
        assign(socket,
          started: true,
          loading: false,
          cancelling: false,
          poll_gen: 0,
          last_input: %{},
          session: nil,
          error: nil,
          users: Accounts.list_users(),
          form: to_form(%{}, as: :setup)
        )

      {:ok, begin(socket)}
    end
  end

  # An unknown instance id never reaches the guest; the modal still renders
  # (root id intact) with the error and a Cancel button.
  defp begin(%{assigns: %{slug: slug, instance_id: nil, entry_step: step}} = socket),
    do: run(socket, fn -> Setup.start(slug, nil, step: step || "start") end)

  defp begin(%{assigns: %{slug: slug, instance_id: id, entry_step: step}} = socket) do
    case Instances.get(id) do
      nil -> assign(socket, :error, "This instance no longer exists.")
      instance -> run(socket, fn -> Setup.start(slug, instance, step: step || "start") end)
    end
  end

  @impl true
  # The operator cancelled while a call was running: wait for it to land, then
  # cancel the session it produced so a draft instance never leaks.
  def handle_async(
        :setup,
        {:ok, {:ok, %Session{} = session}},
        %{assigns: %{cancelling: true}} = socket
      ),
      do: {:noreply, cancel_and_close(socket, session)}

  def handle_async(:setup, _result, %{assigns: %{cancelling: true}} = socket),
    do: {:noreply, cancel_and_close(socket, socket.assigns.session)}

  def handle_async(:setup, {:ok, {:ok, %Session{} = session}}, socket) do
    {:noreply,
     socket
     |> assign(loading: false, session: session, error: session.error)
     |> assign(form: form_for_screen(session, socket.assigns.last_input))
     |> schedule_poll(session)}
  end

  def handle_async(:setup, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, loading: false, error: start_error(reason))}
  end

  def handle_async(:setup, {:exit, _reason}, socket) do
    {:noreply, assign(socket, loading: false, error: "Setup stopped unexpectedly. Try again.")}
  end

  @impl true
  def handle_event("cancel", _params, %{assigns: %{loading: true}} = socket),
    do: {:noreply, assign(socket, :cancelling, true)}

  def handle_event(_event, _params, %{assigns: %{loading: true}} = socket),
    do: {:noreply, socket}

  def handle_event("choose", %{"option_id" => option_id}, socket),
    do: advance(socket, %{"option_id" => option_id})

  def handle_event("submit_form", %{"setup" => params}, socket), do: advance(socket, params)

  def handle_event("save_mapping", params, socket),
    do: advance(socket, %{"mapping" => params["mapping"] || %{}})

  def handle_event("popup_closed", _params, socket) do
    # Invalidate any pending timer, then poll now; the reply starts a new chain.
    socket = assign(socket, :poll_gen, socket.assigns.poll_gen + 1)
    {:ok, socket} = update(%{poll: true}, socket)
    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, cancel_and_close(socket, socket.assigns.session)}

  def handle_event("close", _params, socket), do: {:noreply, close(socket, :done)}

  defp advance(%{assigns: %{session: %Session{} = session}} = socket, input) do
    {:noreply,
     socket
     |> assign(:last_input, input)
     |> run(fn -> Setup.advance(session, input) end)}
  end

  defp advance(socket, _input), do: {:noreply, socket}

  defp run(socket, fun) do
    socket
    |> assign(:loading, true)
    |> start_async(:setup, fun)
  end

  defp schedule_poll(socket, %Session{
         status: :active,
         screen: %{body: {:external_auth, %{poll_after_seconds: seconds}}}
       }) do
    gen = socket.assigns.poll_gen + 1

    send_update_after(
      __MODULE__,
      %{id: socket.assigns.id, poll: true, gen: gen},
      max(seconds, 1) * 1000
    )

    assign(socket, :poll_gen, gen)
  end

  defp schedule_poll(socket, _session), do: socket

  defp start_error(%Error{message: message}) when is_binary(message),
    do: "Setup could not start: #{message}"

  defp start_error(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)

    "Setup could not start: #{details}"
  end

  defp start_error(_reason), do: "Setup could not start. Try again."

  defp cancel_and_close(socket, session) do
    if session, do: Setup.cancel(session)
    close(socket, :cancelled)
  end

  defp close(socket, status) do
    instance_id =
      case socket.assigns.session do
        %Session{instance_id: id} when status == :done -> id
        _ -> nil
      end

    send(
      self(),
      {__MODULE__, :closed, %{id: socket.assigns.id, status: status, instance_id: instance_id}}
    )

    socket
  end

  defp form_for_screen(%Session{screen: %{body: {:form, %{fields: fields}}}, error: error}, input) do
    defaults = Map.new(fields, fn field -> {field.key, field.default_value || ""} end)

    # A host validation error re-renders the same screen: keep what was typed.
    typed = if error, do: Map.take(input, Map.keys(defaults)), else: %{}

    defaults |> Map.merge(typed) |> to_form(as: :setup)
  end

  defp form_for_screen(_session, _input), do: to_form(%{}, as: :setup)

  defp suggested_user(suggestions, account_id) do
    Enum.find_value(suggestions, "", fn
      %{remote_account_id: ^account_id, user_id: user_id} -> user_id
      _ -> nil
    end)
  end

  defp user_options(users), do: [{"Not linked", ""} | Enum.map(users, &{&1.username, &1.id})]

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="modal modal-open">
      <div class="modal-box max-w-xl">
        <h3 class="text-lg font-bold mb-4">{@title}</h3>

        <div :if={@error} id={"#{@id}-error"} class="alert alert-error mb-4">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>{@error}</span>
        </div>

        <div :if={@loading} id={"#{@id}-loading"} class="flex justify-center py-6">
          <span class="loading loading-spinner loading-md"></span>
        </div>

        <div class={[@loading && "opacity-50 pointer-events-none"]}>
          <.screen
            :if={@session && @session.screen}
            screen={@session.screen}
            form={@form}
            users={@users}
            myself={@myself}
          />
        </div>

        <div class="modal-action">
          <.button
            :if={!(@session && @session.status == :done)}
            id="setup-cancel"
            type="button"
            class="btn btn-ghost"
            phx-click="cancel"
            phx-target={@myself}
          >
            Cancel
          </.button>
          <.button
            :if={@session && @session.status == :done}
            id="setup-close"
            type="button"
            variant="primary"
            phx-click="close"
            phx-target={@myself}
          >
            Close
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr :screen, :map, required: true
  attr :form, :any, required: true
  attr :users, :list, required: true
  attr :myself, :any, required: true

  defp screen(%{screen: %{body: {:choice, choice}}} = assigns) do
    assigns = assign(assigns, :choice, choice)

    ~H"""
    <p class="font-medium mb-3">{@choice.title}</p>
    <ul class="space-y-2">
      <li :for={option <- @choice.options}>
        <.button
          id={"setup-option-#{option.id}"}
          type="button"
          class="btn btn-outline w-full justify-between h-auto py-3"
          phx-click="choose"
          phx-value-option_id={option.id}
          phx-target={@myself}
        >
          <span class="text-left">
            <span class="block font-medium">{option.label}</span>
            <span :if={option.detail} class="block text-xs text-base-content/60">
              {option.detail}
            </span>
            <%!-- Choosing approves these addresses, and the plugin supplied them. --%>
            <span
              :for={{endpoint, index} <- Enum.with_index(option.endpoints)}
              id={"setup-option-#{option.id}-endpoint-#{index}"}
              class="mt-1 flex flex-wrap items-center gap-1 text-xs font-mono text-base-content/70"
            >
              {Instance.endpoint_label(endpoint)}
              <span :if={Instance.endpoint_private?(endpoint)} class="badge badge-warning badge-xs">
                private network
              </span>
            </span>
          </span>
          <span :if={option.badge} class="badge badge-ghost">{option.badge}</span>
        </.button>
      </li>
    </ul>
    """
  end

  defp screen(%{screen: %{body: {:form, form_screen}}} = assigns) do
    assigns =
      assigns
      |> assign(:fields, Enum.map(form_screen.fields, &setup_field_to_settings_field/1))
      |> assign(:title, form_screen.title)

    ~H"""
    <p class="font-medium mb-3">{@title}</p>
    <.form for={@form} id="setup-form" phx-submit="submit_form" phx-target={@myself}>
      <div class="space-y-3">
        <.settings_field :for={field <- @fields} field={field} form={@form} />
      </div>
      <div class="mt-4 flex justify-end">
        <.button type="submit" variant="primary">Continue</.button>
      </div>
    </.form>
    """
  end

  defp screen(%{screen: %{body: {:external_auth, auth}}} = assigns) do
    assigns = assign(assigns, :auth, auth)

    ~H"""
    <div
      id="setup-external-auth"
      phx-hook="ExternalAuthPopup"
      data-url={@auth.url}
      phx-target={@myself}
      class="flex flex-col items-center gap-3 py-4 text-center"
    >
      <span class="loading loading-dots loading-md"></span>
      <p>{@auth.message || "Finish signing in in the window that opened."}</p>
      <a
        id="setup-external-auth-link"
        href={@auth.url}
        target="_blank"
        rel="noopener noreferrer"
        class="link link-primary text-sm"
      >
        Open the sign-in page
      </a>
    </div>
    """
  end

  defp screen(%{screen: %{body: {:mapping, mapping}}} = assigns) do
    assigns = assign(assigns, :mapping, mapping)

    ~H"""
    <p class="font-medium mb-3">{@mapping.title}</p>
    <.form for={@form} id="setup-mapping-form" phx-submit="save_mapping" phx-target={@myself}>
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Account</th>
            <th>Mydia user</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={account <- @mapping.accounts}>
            <td>
              {account.name}
              <span :if={account.admin} class="badge badge-ghost badge-sm ml-1">admin</span>
            </td>
            <td>
              <.input
                id={"setup-mapping-#{account.id}"}
                type="select"
                name={"mapping[#{account.id}]"}
                value={suggested_user(@mapping.suggestions, account.id)}
                options={user_options(@users)}
              />
            </td>
          </tr>
        </tbody>
      </table>
      <div class="mt-4 flex justify-end">
        <.button type="submit" variant="primary">Save links</.button>
      </div>
    </.form>
    """
  end

  defp screen(%{screen: %{body: {:done, summary}}} = assigns) do
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <div id="setup-done" class="alert alert-success">
      <.icon name="hero-check-circle" class="w-5 h-5" />
      <span>{@summary}</span>
    </div>
    """
  end
end
