defmodule Mydia.Jobs.MediaImport.Args do
  @moduledoc false
  defstruct [
    :download_id,
    :target_files,
    :save_path,
    snooze_count: 0,
    use_hardlinks: true,
    move_source: false,
    rename_files: false
  ]

  @type t :: %__MODULE__{
          download_id: String.t() | nil,
          target_files: [map()] | nil,
          save_path: String.t() | nil,
          snooze_count: integer(),
          use_hardlinks: boolean(),
          move_source: boolean(),
          rename_files: boolean()
        }

  def parse(%{"download_id" => download_id} = raw) do
    %__MODULE__{
      download_id: download_id,
      target_files: Map.get(raw, "target_files"),
      save_path: parse_save_path(Map.get(raw, "save_path")),
      snooze_count: Map.get(raw, "snooze_count", 0),
      use_hardlinks: Map.get(raw, "use_hardlinks", true) != false,
      rename_files: Map.get(raw, "rename_files", false) == true
    }
  end

  defp parse_save_path(save_path) when save_path in [nil, ""], do: nil
  defp parse_save_path(save_path) when is_binary(save_path), do: save_path
end
