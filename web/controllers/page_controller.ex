defmodule ApathyDrive.PageController do
  use ApathyDrive.Web, :controller

  plug :action

  def index(conn, _params) do
    render conn, "index.html"
  end

  def game(conn, %{"id" => _id}) do
    render conn, "game.html", []
  end

  def game(conn, _params) do
    url = Systems.Login.create
    redirect conn, to: ApathyDrive.Router.Helpers.game_path(conn, :game, url)
  end
end
