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

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Plugins.get_plugin(slug) do
      {:ok, %Plugin{enabled: true, page: %{"title" => title}} = plugin} ->
        if Plugin.granted?(plugin, "surfaces:page") do
          session_id = Ecto.UUID.generate()
          if connected?(socket), do: schedule_token_refresh()

          {:ok,
           socket
           |> assign(:page_title, title)
           |> assign(:slug, slug)
           |> assign(:title, title)
           |> assign(:session_id, session_id)
           |> assign(:frame_src, frame_src(slug, user, session_id))
           |> assign(:choices, Grants.allowed_choices(slug, user.role))
           |> assign(:pending, nil)}
        else
          {:ok, push_navigate(socket, to: ~p"/")}
        end

      _ ->
        {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("confirm_writes", %{"ids" => ids}, socket) when is_list(ids) do
    %{slug: slug, session_id: sid, current_user: user} = socket.assigns
    ids = Enum.filter(ids, &is_binary/1)

    case PageActions.pending(slug, user.id, sid, ids) do
      {:ok, [_ | _] = rows} -> {:noreply, assign(socket, :pending, rows)}
      _ -> {:noreply, post(socket, %{"mydia" => "expired", "ids" => ids})}
    end
  end

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

      {:error, _} ->
        {:noreply, socket |> assign(:pending, nil) |> post(%{"mydia" => "expired", "ids" => ids})}
    end
  end

  @impl true
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
        <h1 class="text-xl font-semibold">{@title}</h1>
        <div
          id="plugin-frame-host"
          phx-hook="PluginFrame"
          phx-update="ignore"
          class="flex-1 rounded-box overflow-hidden border border-base-300 bg-base-100"
        >
          <iframe
            id="plugin-frame"
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
