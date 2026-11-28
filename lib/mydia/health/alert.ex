defmodule Mydia.Health.Alert do
  @moduledoc """
  A fatal condition that has lasted long enough to show to admins.

  Built by `Mydia.Health.Alerts.Evaluator`. `since` is when the condition was
  first observed failing in this run, kept across short recoveries so a
  flapping outage reads as one. `fix_path` is the admin page that fixes it.
  """

  @enforce_keys [:key, :title, :since, :fix_path]
  defstruct [:key, :title, :detail, :since, :fix_path]

  @type t :: %__MODULE__{
          key: term(),
          title: String.t(),
          detail: String.t() | nil,
          since: DateTime.t(),
          fix_path: String.t()
        }
end
