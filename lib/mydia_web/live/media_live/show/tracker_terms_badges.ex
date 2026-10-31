defmodule MydiaWeb.MediaLive.Show.TrackerTermsBadges do
  @moduledoc """
  Badges for a release's tracker terms in the manual search dialog: `FL` for
  freeleech, the download percentage for a partial freeleech (`50%`), the upload
  multiplier (`2x up`), and a lock for a private tracker.

  Every term may be unknown (nil), and an unknown term renders nothing. A
  download factor of 1 or an upload factor of 1 is the normal case and renders
  nothing either.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext
  import MydiaWeb.CoreComponents, only: [icon: 1]

  alias Mydia.Indexers.Structs.TrackerTerms

  attr :id, :string, required: true
  attr :terms, TrackerTerms, default: nil

  def terms_badges(assigns) do
    terms = assigns.terms || %TrackerTerms{}

    assigns =
      assign(assigns,
        download: download_badge(terms.download_volume_factor),
        upload: upload_badge(terms.upload_volume_factor),
        private?: terms.private? == true
      )

    ~H"""
    <span
      :if={@download}
      id={"#{@id}-freeleech"}
      class={["badge badge-sm", elem(@download, 0)]}
      title={elem(@download, 2)}
    >
      {elem(@download, 1)}
    </span>
    <span
      :if={@upload}
      id={"#{@id}-upload"}
      class="badge badge-sm badge-info"
      title={elem(@upload, 1)}
    >
      {elem(@upload, 0)}
    </span>
    <span
      :if={@private?}
      id={"#{@id}-private"}
      class="badge badge-sm badge-ghost"
      title={gettext("Private tracker")}
    >
      <.icon name="hero-lock-closed" class="w-3 h-3" />
      <span class="sr-only">{gettext("Private tracker")}</span>
    </span>
    """
  end

  # A negative factor is malformed, not "better than freeleech", and a factor
  # that rounds to 100% is no discount worth a badge.
  defp download_badge(factor) when factor == 0,
    do:
      {"badge-success", gettext("FL"),
       gettext("Freeleech: the download does not count toward your ratio")}

  defp download_badge(factor) when is_number(factor) and factor > 0,
    do: partial_badge(round(factor * 100))

  defp download_badge(_factor), do: nil

  defp partial_badge(percent) when percent < 100,
    do:
      {"badge-info", "#{percent}%",
       gettext("Only %{percent}% of the download counts toward your ratio", percent: percent)}

  defp partial_badge(_percent), do: nil

  defp upload_badge(factor) when is_number(factor) and factor > 1 do
    multiplier = format_multiplier(factor)

    {gettext("%{multiplier}x up", multiplier: multiplier),
     gettext("Uploads count %{multiplier} times toward your ratio", multiplier: multiplier)}
  end

  defp upload_badge(_factor), do: nil

  defp format_multiplier(factor) when factor == trunc(factor),
    do: Integer.to_string(trunc(factor))

  defp format_multiplier(factor), do: factor |> Float.round(2) |> Float.to_string()
end
