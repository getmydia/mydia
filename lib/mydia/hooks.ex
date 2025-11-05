defmodule Mydia.Hooks do
  @moduledoc """
  Hooks system for extensible lifecycle event customization.

  Provides a way for users to execute custom logic at key application
  lifecycle events such as media addition, downloads, imports, etc.

  ## Configuration

  The hooks system is configured in `config.yaml`:

      hooks:
        enabled: true
        directory: "hooks"  # Relative to database directory
        default_timeout_ms: 5000
        max_timeout_ms: 30000

  ## Directory Resolution

  The hooks directory is resolved relative to the database directory:
  - Development: `mydia_dev.db` + `hooks` = `./hooks`
  - Production: `/config/mydia.db` + `hooks` = `/data/hooks`

  This means hooks live alongside your data, making backups and Docker
  deployments simpler.

  ## Hook Execution

  Hooks are Lua scripts placed in the hooks directory, organized
  by event name. For example:

      hooks/after_media_added/01_my_hook.lua

  Hooks are executed in priority order (determined by filename prefix).

  ## Usage

      # Execute all hooks for an event
      Mydia.Hooks.execute("after_media_added", event_data)

      # Execute hooks asynchronously (fire and forget)
      Mydia.Hooks.execute_async("on_download_completed", event_data)
  """

  alias Mydia.Hooks.{Manager, Executor}

  @doc """
  Execute all hooks for a given event synchronously.

  Returns `{:ok, result}` with the modified data, or `{:error, reason}`.
  If any hook fails, execution continues with the next hook (fail-soft).
  """
  @spec execute(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(event, data, opts \\ []) do
    Executor.execute_sync(event, data, opts)
  end

  @doc """
  Execute all hooks for a given event asynchronously.

  Hooks are executed in the background and failures are logged but
  do not block the caller. Returns `:ok` immediately.
  """
  @spec execute_async(String.t(), map(), keyword()) :: :ok
  def execute_async(event, data, opts \\ []) do
    Executor.execute_async(event, data, opts)
  end

  @doc """
  List all registered hooks for a given event.
  """
  @spec list_hooks(String.t()) :: [map()]
  def list_hooks(event) do
    Manager.list_hooks(event)
  end

  @doc """
  List all available hook events.
  """
  @spec list_events() :: [String.t()]
  def list_events do
    Manager.list_events()
  end

  @doc """
  Reload hooks from disk. Useful for development.
  """
  @spec reload() :: :ok
  def reload do
    Manager.reload()
  end
end
