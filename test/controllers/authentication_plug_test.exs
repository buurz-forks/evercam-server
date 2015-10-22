defmodule EvercamMedia.AuthenticationPlugTest do
  use EvercamMedia.PlugCase

  test "returns HTTP 401 with error message if api_id and api_key are invalid" do
    conn = conn(:put, "/v1/users")
    conn = EvercamMedia.Router.call(conn, @opts)

    assert conn.state == :sent
    assert conn.status == 401
    assert Poison.decode!(conn.resp_body) == %{"error" => %{"message" => "Invalid API keys"}}
  end

  test "returns HTTP 200 if api_id and api_key are valid" do
    {:ok, country} = EvercamMedia.Repo.insert(%Country{name: "Whatever", iso3166_a2: "WHT"})
    {:ok, user} = EvercamMedia.Repo.insert(%User{ firstname: "Paul", lastname: "McCartney", 
        username: "paulm", password: "whatever", email: "paul@mccartney.com", 
        api_id: "some_api_id", api_key: "some_api_key", country_id: country.id})

    c = conn(:put, "/v1/users/#{user.id}", %{ "user" => %{ firstname: "whatever" }} )
      |> Plug.Conn.put_req_header("x-api-key", user.api_key)
      |> Plug.Conn.put_req_header("x-api-id", user.api_id)
      |> EvercamMedia.Router.call(@opts)

    assert c.state == :sent
    assert c.status == 200
  end
end
