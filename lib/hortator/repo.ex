defmodule Hortator.Repo do
  use Ecto.Repo,
    otp_app: :hortator,
    adapter: Ecto.Adapters.Postgres
end
