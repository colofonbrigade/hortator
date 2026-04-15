defmodule HortatorWeb.ErrorJSONTest do
  use HortatorWeb.ConnCase, async: true

  test "renders 404" do
    assert HortatorWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert HortatorWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
