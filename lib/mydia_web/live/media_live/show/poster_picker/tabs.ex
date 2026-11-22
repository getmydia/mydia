defmodule MydiaWeb.MediaLive.Show.PosterPicker.Tabs do
  @moduledoc """
  The three tabs of `MydiaWeb.MediaLive.Show.PosterPicker` (Browse, Upload and
  From folder) and the messages they show. Each tab only renders; selection
  and saving stay in the picker component, which every tab targets with
  `myself`.
  """

  use MydiaWeb, :html

  alias Mydia.Media.Posters
  alias Mydia.Metadata.ImageUrl

  @doc "The message shown for a failed save."
  def error_message(:unsupported_format),
    do: gettext("That file is not a JPEG, PNG or WebP image.")

  def error_message(:too_large), do: gettext("That image is larger than 10 MB.")
  def error_message(:not_found), do: gettext("That file is no longer in the item's folder.")
  def error_message(:invalid_poster), do: gettext("That poster cannot be used.")

  def error_message(reason) when reason in [:unauthorized, :restricted],
    do: gettext("You do not have permission to change this poster.")

  def error_message(_), do: gettext("The poster could not be saved.")

  defp upload_error_message(:too_large), do: error_message(:too_large)
  defp upload_error_message(:not_accepted), do: error_message(:unsupported_format)
  defp upload_error_message(:too_many_files), do: gettext("Choose one image.")
  defp upload_error_message(_), do: error_message(:other)

  defp candidate_src(item, %Posters.Candidate{} = c) do
    ~p"/media/#{item.id}/poster-candidates/#{c.library_path_id}/#{Path.split(c.relative_path)}"
  end

  attr :browse, :atom, required: true
  attr :results, :list, required: true
  attr :selected, :integer, default: nil
  attr :current_path, :string, default: nil
  attr :myself, :any, required: true

  def browse_tab(assigns) do
    ~H"""
    <%= case @browse do %>
      <% :loading -> %>
        <div class="flex justify-center py-12">
          <span class="loading loading-spinner loading-lg"></span>
        </div>
      <% :error -> %>
        <div id="poster-browse-error" class="alert alert-error" role="alert">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>{gettext("Could not load posters from the metadata provider.")}</span>
          <button type="button" class="btn btn-sm" phx-click="retry_browse" phx-target={@myself}>
            {gettext("Retry")}
          </button>
        </div>
      <% :ok -> %>
        <p :if={@results == []} class="text-sm opacity-70 py-8 text-center">
          {gettext("The metadata provider has no posters for this title.")}
        </p>
        <div class="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 gap-3">
          <button
            :for={{{source, poster}, index} <- Enum.with_index(@results)}
            id={"poster-option-#{index}"}
            type="button"
            aria-pressed={to_string(@selected == index)}
            class={[
              "relative rounded-box overflow-hidden border-2 transition-colors",
              if(@selected == index,
                do: "border-primary",
                else: "border-transparent hover:border-base-content/30"
              )
            ]}
            phx-click="select_option"
            phx-value-index={index}
            phx-target={@myself}
          >
            <img
              src={ImageUrl.poster_url(poster.file_path, "w185")}
              alt=""
              loading="lazy"
              class="aspect-[2/3] w-full object-cover bg-base-300"
            />
            <span class="absolute bottom-1 left-1 flex gap-1">
              <span class="badge badge-xs badge-neutral">{source}</span>
              <span :if={poster.language} class="badge badge-xs badge-neutral">
                {poster.language}
              </span>
            </span>
            <span
              :if={poster.file_path == @current_path}
              class="badge badge-xs badge-primary absolute top-1 right-1"
            >
              {gettext("Current")}
            </span>
          </button>
        </div>
    <% end %>
    """
  end

  attr :uploads, :map, required: true
  attr :myself, :any, required: true

  def upload_tab(assigns) do
    ~H"""
    <form
      id="poster-upload-form"
      phx-change="validate_upload"
      phx-submit="save"
      phx-target={@myself}
      class="flex flex-col gap-4"
    >
      <label class="flex flex-col gap-2">
        <span class="text-sm opacity-75">
          {gettext("JPEG, PNG or WebP, up to 10 MB.")}
        </span>
        <.live_file_input upload={@uploads.poster} class="file-input w-full" />
      </label>

      <div :for={entry <- @uploads.poster.entries} class="flex items-start gap-4">
        <.live_img_preview entry={entry} class="w-32 aspect-[2/3] object-cover rounded-box" />
        <div class="flex-1 min-w-0">
          <p class="text-sm truncate">{entry.client_name}</p>
          <p
            :for={err <- upload_errors(@uploads.poster, entry)}
            class="text-sm text-error"
          >
            {upload_error_message(err)}
          </p>
          <button
            type="button"
            class="btn btn-ghost btn-xs mt-2"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            phx-target={@myself}
          >
            {gettext("Remove")}
          </button>
        </div>
      </div>

      <p :for={err <- upload_errors(@uploads.poster)} class="text-sm text-error">
        {upload_error_message(err)}
      </p>
    </form>
    """
  end

  attr :candidates, :any, required: true
  attr :selected, :integer, default: nil
  attr :media_item, :map, required: true
  attr :myself, :any, required: true

  def folder_tab(assigns) do
    ~H"""
    <%= cond do %>
      <% @candidates == :loading -> %>
        <div class="flex justify-center py-12">
          <span class="loading loading-spinner loading-lg"></span>
        </div>
      <% @candidates == [] -> %>
        <p class="text-sm opacity-70 py-8 text-center">
          {gettext("No JPEG, PNG or WebP files sit next to this item's files.")}
        </p>
      <% true -> %>
        <div class="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 gap-3">
          <button
            :for={{candidate, index} <- Enum.with_index(@candidates)}
            id={"poster-candidate-#{index}"}
            type="button"
            aria-pressed={to_string(@selected == index)}
            class={[
              "flex flex-col rounded-box overflow-hidden border-2 transition-colors text-left",
              if(@selected == index,
                do: "border-primary",
                else: "border-transparent hover:border-base-content/30"
              )
            ]}
            phx-click="select_candidate"
            phx-value-index={index}
            phx-target={@myself}
          >
            <img
              src={candidate_src(@media_item, candidate)}
              alt=""
              loading="lazy"
              class="aspect-[2/3] w-full object-cover bg-base-300"
            />
            <span class="text-xs truncate px-1 py-0.5">{candidate.name}</span>
          </button>
        </div>
    <% end %>
    """
  end
end
