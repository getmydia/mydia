defmodule MydiaWeb.PluginPageLive.Show do
  @moduledoc """
  Hosts a plugin page in a sandboxed iframe and owns the write confirmation
  modal. The modal text comes from the host's pending-write rows, never from
  the plugin, and the allow or deny decision is only ever taken from a click in
  this LiveView, using this LiveView's own user and session id.

  The frame token in the iframe URL lives one hour, so the view re-mints it well
  before expiry and posts the fresh one to the frame.
  """
  use MydiaWeb, :live_view

  alias Mydia.Plugins
  alias Mydia.Plugins.Grants
  alias Mydia.Plugins.PageActions
  alias Mydia.Plugins.Plugin
  alias MydiaWeb.PluginFrameToken
  alias MydiaWeb.PluginPageLive.Components

  # Well inside the token's one hour lifetime.
  @token_refresh_ms 45 * 60 * 1000
  @max_ids 50

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Plugins.get_plugin(slug) do
      {:ok, %Plugin{enabled: true, page: %{"title" => title}} = plugin} ->
        if Plugin.granted?(plugin, "surfaces:page") do
          {:ok,
           socket
           |> assign(:page_title, title)
           |> assign(:slug, slug)
           |> assign(:title, title)
           |> start_session(slug, user)
           |> assign(:choices, Grants.allowed_choices(slug, user.role))
           |> assign(:pending, nil)}
        else
          {:ok, push_navigate(socket, to: ~p"/")}
        end

      _ ->
        {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  # The mount runs twice on a page load (static render, then connected). The
  # browser keeps the iframe from whichever render created it, so only the
  # connected mount mints the page session and renders the frame; otherwise the
  # frame and this process would hold different session ids. The frame's id
  # carries the session id, so a reconnect (which mints a new session) replaces
  # the iframe instead of keeping one that holds the old token. Session grants
  # from earlier page sessions can never apply again, so they are pruned here.
  defp start_session(socket, slug, user) do
    if connected?(socket) do
      session_id = Ecto.UUID.generate()
      schedule_token_refresh()
      Grants.prune_sessions(user.id, slug, session_id)

      socket
      |> assign(:session_id, session_id)
      |> assign(:frame_src, frame_src(slug, user, session_id))
    else
      socket |> assign(:session_id, nil) |> assign(:frame_src, nil)
    end
  end

  # A frame can only ask; while a decision is pending, further requests are
  # ignored so the rows under the user's cursor cannot change.
  @impl true
  def handle_event("confirm_writes", _params, %{assigns: %{pending: [_ | _]}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_writes", %{"ids" => ids}, socket) when is_list(ids) do
    %{slug: slug, session_id: sid, current_user: user} = socket.assigns
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.take(@max_ids)

    with [_ | _] <- ids,
         {:ok, [_ | _] = rows} <- PageActions.pending(slug, user.id, sid, ids) do
      {:noreply, assign(socket, :pending, rows)}
    else
      [] -> {:noreply, socket}
      _ -> {:noreply, post(socket, %{"mydia" => "expired", "ids" => ids})}
    end
  end

  def handle_event("confirm_writes", _params, socket), do: {:noreply, socket}

  def handle_event("decide", _params, %{assigns: %{pending: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("decide", %{"choice" => "deny"}, socket) do
    %{slug: slug, session_id: sid, current_user: user, pending: rows} = socket.assigns
    ids = Enum.map(rows, & &1.id)
    :ok = PageActions.deny(slug, user.id, sid, ids)
    {:noreply, socket |> assign(:pending, nil) |> post(%{"mydia" => "denied", "ids" => ids})}
  end

  def handle_event("decide", %{"choice" => choice}, socket) do
    %{slug: slug, session_id: sid, current_user: user, pending: rows} = socket.assigns
    ids = Enum.map(rows, & &1.id)

    case PageActions.confirm(slug, user, sid, ids, choice) do
      {:ok, results} ->
        message = %{
          "mydia" => "confirmed",
          "results" => Enum.map(results, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
        }

        {:noreply, socket |> assign(:pending, nil) |> post(message)}

      {:error, :choice_not_allowed} ->
        :ok = PageActions.deny(slug, user.id, sid, ids)
        {:noreply, socket |> assign(:pending, nil) |> post(%{"mydia" => "denied", "ids" => ids})}

      {:error, _} ->
        {:noreply, socket |> assign(:pending, nil) |> post(%{"mydia" => "expired", "ids" => ids})}
    end
  end

  @impl true
  def handle_info(:refresh_frame_token, %{assigns: %{session_id: nil}} = socket),
    do: {:noreply, socket}

  def handle_info(:refresh_frame_token, socket) do
    %{slug: slug, current_user: user, session_id: sid} = socket.assigns
    schedule_token_refresh()

    {:noreply,
     post(socket, %{"mydia" => "token", "token" => PluginFrameToken.sign(slug, user.id, sid)})}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp schedule_token_refresh,
    do: Process.send_after(self(), :refresh_frame_token, @token_refresh_ms)

  defp frame_src(slug, user, session_id) do
    "/plugins/#{slug}/app/?#{PluginFrameToken.param()}=" <>
      URI.encode_www_form(PluginFrameToken.sign(slug, user.id, session_id))
  end

  defp post(socket, message), do: push_event(socket, "plugin_frame:post", %{message: message})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {assigns}>
      <div class="flex flex-col h-[calc(100dvh-6rem)] gap-3">
        <div class="flex items-center justify-between gap-3">
          <h1 class="text-xl font-semibold">{@title}</h1>
          <.link
            navigate={~p"/plugins/#{@slug}/activity"}
            id="plugin-activity-link"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-clock" class="w-4 h-4" /> Activity
          </.link>
        </div>
        <div
          id="plugin-frame-host"
          phx-hook="PluginFrame"
          class="flex-1 rounded-box overflow-hidden border border-base-300 bg-base-100"
        >
          <iframe
            :if={@frame_src}
            id={"plugin-frame-" <> @session_id}
            phx-update="ignore"
            src={@frame_src}
            sandbox="allow-scripts allow-forms"
            referrerpolicy="no-referrer"
            class="w-full h-full"
            title={@title}
          ></iframe>
        </div>
      </div>
      <Components.confirm_modal :if={@pending} title={@title} pending={@pending} choices={@choices} />
    </Layouts.app>
    """
  end
end
