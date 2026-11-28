defmodule MydiaWeb.HealthAlertText do
  @moduledoc """
  Translated text for `Mydia.Health.Alert`s.

  The domain keeps English titles and never depends on Gettext; this module
  translates the title by alert key and falls back to the alert's own title
  for a key it does not know. Details stay as the domain wrote them, since
  they carry provider messages and paths.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Health.Alert

  @spec title(Alert.t()) :: String.t()
  def title(%Alert{key: :built_in_blocked}),
    do: gettext("Downloads stopped: the built-in client is blocked")

  def title(%Alert{key: :built_in_low_disk}), do: gettext("Downloads paused: low disk space")

  def title(%Alert{key: :all_download_clients_down}),
    do: gettext("Every download client is unreachable")

  def title(%Alert{key: :all_indexers_down}), do: gettext("Every indexer is failing")

  def title(%Alert{key: {:library_root_missing, _}}), do: gettext("A library folder is missing")
  def title(%Alert{title: title}), do: title

  @doc "How long the alert has lasted, such as \"for 3h\". At least one minute."
  @spec duration(Alert.t(), DateTime.t()) :: String.t()
  def duration(%Alert{since: since}, now \\ DateTime.utc_now()) do
    minutes = max(div(DateTime.diff(now, since, :second) + 59, 60), 1)

    cond do
      minutes < 60 -> gettext("for %{count}m", count: minutes)
      minutes < 48 * 60 -> gettext("for %{count}h", count: div(minutes, 60))
      true -> gettext("for %{count}d", count: div(minutes, 24 * 60))
    end
  end
end
