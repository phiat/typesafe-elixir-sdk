# Live API tests are opt-in: `mix test --include integration` with TYPESAFE_API_KEY set.
ExUnit.start(exclude: [:integration])
