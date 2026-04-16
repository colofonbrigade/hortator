defmodule Core.Config.Schema.Claude do
  @moduledoc """
  Embedded schema for the `claude:` section of WORKFLOW.md (Claude Code agent
  runtime settings — command, model, permission mode, timeouts).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

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

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :command,
        :model,
        :permission_mode,
        :mcp_config_path,
        :effort,
        :turn_timeout_ms,
        :read_timeout_ms,
        :stall_timeout_ms
      ],
      empty_values: []
    )
    |> validate_required([:command, :model, :permission_mode])
    |> validate_number(:turn_timeout_ms, greater_than: 0)
    |> validate_number(:read_timeout_ms, greater_than: 0)
    |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
  end
end
