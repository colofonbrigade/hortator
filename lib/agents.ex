defmodule Agents do
  @moduledoc """
  Top-level boundary for agent backends. Each backend lives under a
  sub-namespace (currently `Agents.Claude` for the Claude Code client).
  """

  use Boundary, deps: [Permissions, Transport], exports: [Claude.Session, Claude.Usage]
end
