defmodule MydiaWeb.MediaLive.Show.FixMatchEvents do
  @moduledoc false

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2, start_async: 3]

  use MydiaWeb, :verified_routes

  alias Mydia.Media.FixMatch
  alias Mydia.Metadata.TvProvider
  alias MydiaWeb.Live.Authorization

  require Logger

  def open(_params, socket) do
    case Authorization.authorize_delete_media(socket) do
      :ok ->
        item = socket.assigns.media_item

        {:noreply,
         assign(socket, :fix_match, %{
           step: :search,
           form: form(item.title, item.year),
           results: [],
           searching?: false,
           error: nil,
           picked: nil,
           adopting?: false,
           provider: FixMatch.provider_for(item)
         })}

      {:unauthorized, socket} ->
        {:noreply, socket}
    end
  end

  def close(_params, socket), do: {:noreply, assign(socket, :fix_match, nil)}

  @doc "Routes a `fix_match_<action>` event from `MydiaWeb.MediaLive.Show`."
  def handle_event("search", params, socket), do: search(params, socket)
  def handle_event("provider", params, socket), do: provider(params, socket)
  def handle_event("pick", params, socket), do: pick(params, socket)
  def handle_event("back", params, socket), do: back(params, socket)
  def handle_event("confirm", params, socket), do: confirm(params, socket)

  def search(_params, %{assigns: %{fix_match: nil}} = socket), do: {:noreply, socket}

  def search(%{"fix_match" => %{"query" => query} = params}, socket) when is_binary(query) do
    item = socket.assigns.media_item
    scope = socket.assigns.current_scope
    config = socket.assigns[:metadata_config]
    provider = socket.assigns.fix_match.provider
    year = parse_year(params["year"])
    trimmed = String.trim(query)

    if trimmed == "" do
      {:noreply, update_fix_match(socket, form: form(query, year))}
    else
      {:noreply,
       socket
       |> update_fix_match(form: form(query, year), searching?: true, error: nil)
       |> start_async(:fix_match_search, fn ->
         {provider, FixMatch.search(item, trimmed, year, scope, config, provider: provider)}
       end)}
    end
  end

  def search(_params, socket), do: {:noreply, socket}

  # A result tagged with a provider the modal has since toggled away from is
  # dropped: painting it would show the old provider's ids under the new one.
  # `searching?` stays on, the newer search is still in flight.
  def handle_search_async({:ok, {provider, outcome}}, socket) do
    case socket.assigns.fix_match do
      %{provider: ^provider} -> apply_search_outcome(outcome, socket)
      _ -> {:noreply, socket}
    end
  end

  def handle_search_async({:exit, reason}, socket) do
    Logger.error("Fix match search crashed: #{inspect(reason)}")

    {:noreply,
     update_fix_match(socket, searching?: false, error: gettext("Search failed unexpectedly"))}
  end

  defp apply_search_outcome({:ok, results}, socket),
    do: {:noreply, update_fix_match(socket, results: results, searching?: false)}

  defp apply_search_outcome({:error, reason}, socket) do
    {:noreply,
     update_fix_match(socket,
       searching?: false,
       error: gettext("Search failed: %{reason}", reason: inspect(reason))
     )}
  end

  def pick(_params, %{assigns: %{fix_match: nil}} = socket), do: {:noreply, socket}

  def pick(%{"provider_id" => provider_id}, socket) do
    current = FixMatch.current_provider_id(socket.assigns.media_item)

    picked =
      Enum.find(socket.assigns.fix_match.results, &(to_string(&1.provider_id) == provider_id))

    same_identity? =
      provider_id == current and
        socket.assigns.fix_match.provider == FixMatch.provider_for(socket.assigns.media_item)

    if picked && not same_identity? do
      {:noreply, update_fix_match(socket, step: :confirm, picked: picked)}
    else
      {:noreply, socket}
    end
  end

  def provider(_params, %{assigns: %{fix_match: nil}} = socket), do: {:noreply, socket}

  def provider(%{"provider" => value}, socket) do
    case TvProvider.parse(value) do
      nil ->
        {:noreply, socket}

      provider ->
        socket =
          update_fix_match(socket, provider: provider, results: [], step: :search, picked: nil)

        params = socket.assigns.fix_match.form.params

        if String.trim(params["query"] || "") != "" do
          search(%{"fix_match" => params}, socket)
        else
          {:noreply, socket}
        end
    end
  end

  def back(_params, socket),
    do: {:noreply, update_fix_match(socket, step: :search, picked: nil)}

  def confirm(_params, socket) do
    with :ok <- Authorization.authorize_delete_media(socket),
         %{picked: %{} = picked, adopting?: false} <- socket.assigns.fix_match do
      item = socket.assigns.media_item
      scope = socket.assigns.current_scope
      config = socket.assigns[:metadata_config]
      provider = socket.assigns.fix_match.provider

      {:noreply,
       socket
       |> update_fix_match(adopting?: true)
       |> start_async(:fix_match_adopt, fn ->
         FixMatch.adopt(scope, item, picked, config, provider: provider)
       end)}
    else
      {:unauthorized, socket} -> {:noreply, socket}
      _ -> {:noreply, socket}
    end
  end

  def handle_adopt_async({:ok, {:ok, updated}}, socket) do
    # Remount: the collection and similar-title sections are derived from the old identity at mount.
    {:noreply,
     socket
     |> assign(:fix_match, nil)
     |> put_flash(:info, gettext("Match changed to %{title}", title: updated.title))
     |> push_navigate(to: ~p"/media/#{updated.id}")}
  end

  def handle_adopt_async({:ok, {:error, {:already_in_library, other}}}, socket) do
    message =
      if other.type == "movie" do
        gettext(
          "%{title} is already in your library. Use \"Not this movie\" on the files to move them there.",
          title: other.title
        )
      else
        gettext(
          "%{title} is already in your library. Use \"Not this show\" on the files to move them there.",
          title: other.title
        )
      end

    {:noreply,
     socket
     |> assign(:fix_match, nil)
     |> put_flash(:error, message)}
  end

  # A show's refusal arrives wrapped by ProviderSwitch's rollback.
  def handle_adopt_async({:ok, {:error, reason}}, socket)
      when reason in [:restricted, {:provider_switch_update_failed, :restricted}] do
    {:noreply,
     socket
     |> assign(:fix_match, nil)
     |> put_flash(:error, MydiaWeb.OperationErrors.restricted_message())}
  end

  def handle_adopt_async({:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:fix_match, nil)
     |> put_flash(
       :error,
       gettext("Could not change the match: %{reason}", reason: inspect(reason))
     )}
  end

  def handle_adopt_async({:exit, reason}, socket) do
    Logger.error("Fix match adopt crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:fix_match, nil)
     |> put_flash(:error, gettext("Could not change the match"))}
  end

  defp form(query, year),
    do: to_form(%{"query" => query || "", "year" => year && to_string(year)}, as: :fix_match)

  # The modal may close while a search is in flight or a stale event arrives.
  defp update_fix_match(%{assigns: %{fix_match: nil}} = socket, _changes), do: socket

  defp update_fix_match(socket, changes),
    do: assign(socket, :fix_match, Map.merge(socket.assigns.fix_match, Map.new(changes)))

  defp parse_year(nil), do: nil

  defp parse_year(value) do
    case Integer.parse(String.trim(value)) do
      {year, ""} when year > 1800 and year < 3000 -> year
      _ -> nil
    end
  end
end
