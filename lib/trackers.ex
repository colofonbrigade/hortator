defmodule Trackers do
  @moduledoc """
  Top-level boundary for issue tracker integrations. Each tracker lives
  under a sub-namespace (currently `Trackers.Linear` for the Linear
  GraphQL client + adapter). `Core.Tracker` dispatches through the
  `Trackers.Linear.Tracker` behaviour with settings threaded in at call
  time.
  """

  use Boundary,
    deps: [Schema],
    exports: [Linear.Adapter, Linear.Client, Linear.ResponseDecoder, Linear.Tracker]
end
