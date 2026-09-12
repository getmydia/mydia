defmodule MydiaWeb.AdminUsersLive.Components do
  @moduledoc """
  Components used only by the admin users LiveView.

  Extracted because index.ex and index.html.heex are both past the ~500 line
  guideline, and the access modal would push them further.
  """

  use MydiaWeb, :html

  alias Mydia.Media.ContentRating
  alias Mydia.Media.MediaCategory

  attr :user, :map, required: true
  attr :restriction, :map, default: nil
  attr :unrated_count, :integer, required: true

  def access_modal(assigns) do
    assigns =
      assigns
      |> assign(:categories, MediaCategory.all())
      |> assign(:thresholds, ContentRating.thresholds())
      |> assign(:selected, selected_categories(assigns.restriction))
      |> assign(:max_age, assigns.restriction && assigns.restriction.max_content_age)

    ~H"""
    <div class="modal modal-open" id="access-modal">
      <div class="modal-box max-w-2xl">
        <h3 class="text-lg font-bold">Library access for {@user.display_name || @user.username}</h3>
        <p class="py-2 text-sm opacity-70">
          Restrict what this account can see, request, and play. Leaving both
          settings untouched gives full access.
        </p>

        <.form for={%{}} as={:access} id="access-form" phx-submit="submit_access">
          <fieldset class="mt-4">
            <legend class="label-text font-semibold">Categories</legend>
            <p class="text-sm opacity-70 mb-2">
              Tick nothing to allow every category.
            </p>
            <div class="filter">
              <input
                :for={category <- @categories}
                type="checkbox"
                class="btn"
                name="access[allowed_categories][]"
                value={category}
                checked={to_string(category) in @selected}
                aria-label={category_label(category)}
              />
            </div>
          </fieldset>

          <fieldset class="mt-6">
            <legend class="label-text font-semibold">Maximum age rating</legend>
            <select
              class="select select-bordered w-full mt-2"
              name="access[max_content_age]"
              id="access-max-age"
            >
              <option value="" selected={is_nil(@max_age)}>No limit</option>
              <option
                :for={{label, age} <- @thresholds}
                value={age}
                selected={@max_age == age}
              >
                {label}
              </option>
            </select>
            <p class="text-sm opacity-70 mt-2" id="unrated-count">
              Setting any limit also hides titles with no rating. {@unrated_count} of your library items currently have none.
            </p>
          </fieldset>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" id="clear-access" phx-click="clear_access">
              Remove all restrictions
            </button>
            <button type="button" class="btn" phx-click="close_access_modal">Cancel</button>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_access_modal"></div>
    </div>
    """
  end

  defp selected_categories(nil), do: []
  defp selected_categories(%{allowed_categories: nil}), do: []
  defp selected_categories(%{allowed_categories: categories}), do: categories

  defp category_label(:movie), do: "Movies"
  defp category_label(:tv_show), do: "TV shows"
  defp category_label(:anime_movie), do: "Anime films"
  defp category_label(:anime_series), do: "Anime series"
  defp category_label(:cartoon_movie), do: "Cartoon films"
  defp category_label(:cartoon_series), do: "Cartoon series"
end
