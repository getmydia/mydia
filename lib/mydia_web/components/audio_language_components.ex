defmodule MydiaWeb.AudioLanguageComponents do
  @moduledoc """
  The audio-language badge shown beside a release in manual search and in the
  Activity results tables, so the reason a dub won or lost is visible right
  where the ranking is.

  Used by two LiveViews, so it is not globally imported; call it by its full
  name.
  """
  use Phoenix.Component

  attr :languages, :list, default: []
  attr :assumed, :boolean, default: false
  attr :rank, :integer, default: nil
  attr :id, :string, default: nil

  def audio_badge(assigns) do
    ~H"""
    <span
      :if={@languages != []}
      id={@id}
      data-test="audio-badge"
      class={[
        "badge badge-sm font-mono whitespace-nowrap",
        if(@assumed, do: "badge-ghost", else: "badge-outline")
      ]}
      title={audio_badge_title(@languages, @assumed, @rank)}
    >
      {audio_badge_label(@languages, @assumed)}
    </span>
    """
  end

  @doc "Short label, e.g. `EN+JA` or `JA (assumed)`."
  @spec audio_badge_label([String.t()], boolean()) :: String.t()
  def audio_badge_label(languages, assumed) do
    label = Enum.map_join(languages, "+", &String.upcase/1)
    if assumed, do: label <> " (assumed)", else: label
  end

  defp audio_badge_title(languages, assumed, rank) do
    names = Enum.map_join(languages, ", ", &MydiaWeb.Languages.name/1)

    base =
      if assumed,
        do: "Audio: #{names}, assumed because the release title names no audio language",
        else: "Audio: #{names}"

    if is_integer(rank), do: "#{base}, preference rank #{rank}", else: base
  end
end
