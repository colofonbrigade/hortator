defmodule HortatorWeb.PageController do
  use HortatorWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
