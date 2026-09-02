defmodule Mydia.ImportLists.FeatureFlags do
  @moduledoc """
  Helper module for checking the Import Lists feature flag.

  This module handles the ENABLE_IMPORT_LISTS feature flag which controls
  whether Import Lists functionality runs at all, not just whether its UI
  is visible.

  When enabled, users can configure external lists (like TMDB watchlists)
  to automatically import media into their libraries.

  ## Features Controlled

  - Navigation link to Import Lists in admin menu
  - Mounting the Import Lists admin LiveView (`/admin/import-lists`); a
    disabled flag redirects instead of rendering the page, so the route
    itself cannot be used to bypass the flag
  - The `Mydia.Jobs.ImportListScheduler` cron job; when disabled it exits
    immediately without enqueueing any sync or auto-add work

  ## Configuration

  The feature flag reads from `:mydia, :features, :import_lists_enabled`
  configuration and defaults to `true` (enabled).

  Set via environment variable:
  - `ENABLE_IMPORT_LISTS=true` - Enable Import Lists (default)
  - `ENABLE_IMPORT_LISTS=false` - Disable Import Lists entirely, including
    the scheduled sync job
  """

  @doc """
  Returns true if Import Lists functionality is enabled, false otherwise.

  Reads from the :import_lists_enabled configuration under the :features key.

  ## Examples

      iex> Mydia.ImportLists.FeatureFlags.enabled?()
      true

      # After setting ENABLE_IMPORT_LISTS=false environment variable
      iex> Mydia.ImportLists.FeatureFlags.enabled?()
      false

  """
  def enabled? do
    Application.get_env(:mydia, :features, [])
    |> Keyword.get(:import_lists_enabled, true)
  end
end
