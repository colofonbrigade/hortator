defmodule Web.PageController do
  use Web, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
