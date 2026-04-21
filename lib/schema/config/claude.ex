defmodule Schema.Config.Claude do
  @moduledoc """
  Struct definition for the claude section of WORKFLOW.md (Claude Code agent
  runtime settings — command, model, permission mode, timeouts).
  """

  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{}

  embedded_schema do
    field(:command, :string, default: "claude")
    field(:model, :string, default: "claude-sonnet-4-6")
    field(:permission_mode, :string, default: "bypassPermissions")
    field(:mcp_config_path, :string)
    field(:effort, :string)
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    field(:read_timeout_ms, :integer, default: 5_000)
    field(:stall_timeout_ms, :integer, default: 300_000)
  end
end
