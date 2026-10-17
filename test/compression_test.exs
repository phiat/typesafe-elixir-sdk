defmodule TypeSafe.CompressionTest do
  # These tests read the request off a real socket. Req.Test's plug adapter
  # decompresses a request body (and drops its content-encoding header) before the
  # plug sees it, so it can't show what is actually sent.
  use ExUnit.Case, async: true

  alias TypeSafe.Image

  @png <<0x89, "PNG\r\n", 0x1A, "\n">> <> :binary.copy(<<7>>, 4000)
  @zstd? Code.ensure_loaded?(:zstd) and function_exported?(:zstd, :compress, 1)

  @ok_body Jason.encode!(%{
             "model" => "jev-1.14.0",
             "answers" => %{"billing" => %{"type" => "noul", "noul" => 0.9}},
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           })

  # Serves one response per entry, in order, each on its own connection, and
  # sends the test `{:request, headers, body}` for every request it receives.
  defp serve(statuses) do
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept_each(listen, test, statuses) end)
    "http://127.0.0.1:#{port}"
  end

  defp accept_each(listen, _test, []), do: :gen_tcp.close(listen)

  defp accept_each(listen, test, [status | rest]) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {headers, body} = read_request(socket)
    send(test, {:request, headers, body})

    {reason, payload} =
      if status == 200, do: {"OK", @ok_body}, else: {"Overloaded", ~s({"error":"x"})}

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\n",
      "content-length: #{byte_size(payload)}\r\nconnection: close\r\n\r\n",
      payload
    ])

    :gen_tcp.close(socket)
    accept_each(listen, test, rest)
  end

  defp read_request(socket, buffer \\ "") do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [_request_line | lines] = String.split(head, "\r\n")

        headers =
          Map.new(lines, fn line ->
            [name, value] = String.split(line, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        length = String.to_integer(Map.get(headers, "content-length", "0"))
        {headers, read_body(socket, rest, length)}

      [_incomplete] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 2_000)
        read_request(socket, buffer <> more)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 2_000)
    read_body(socket, body <> more, length)
  end

  defp client(url, opts \\ []) do
    TypeSafe.new([api_key: "test-key", base_url: url, retry: [backoff_initial: 0]] ++ opts)
  end

  defp questions, do: %{billing: TypeSafe.noul("Is this about billing?")}

  defp long_state, do: %{log: String.duplicate("The customer repeats themselves. ", 100)}

  defp decode("gzip", raw), do: :zlib.gunzip(raw)
  defp decode("zstd", raw), do: IO.iodata_to_binary(:zstd.decompress(raw))

  test "compression is off unless asked for" do
    url = serve([200])

    assert {:ok, _} = TypeSafe.system_one(client(url), long_state(), questions())
    assert_received {:request, headers, body}

    refute Map.has_key?(headers, "content-encoding")
    assert headers["content-type"] == "application/json"
    assert Jason.decode!(body)["state"]["log"] == long_state().log
  end

  for name <- ["gzip", "zstd"] do
    @codec name

    @tag skip: if(name == "zstd" and not @zstd?, do: "needs Erlang/OTP 28 or later")
    test "#{name} bodies say so and decode to the same request" do
      url = serve([200, 200])
      codec = String.to_existing_atom(@codec)

      assert {:ok, response} =
               TypeSafe.system_one(client(url, compression: codec), long_state(), questions())

      assert response.answers.billing.noul == 0.9
      assert_received {:request, headers, body}

      assert headers["content-encoding"] == @codec
      assert headers["content-type"] == "application/json"
      assert String.to_integer(headers["content-length"]) == byte_size(body)
      assert byte_size(body) < 200

      request = Jason.decode!(decode(@codec, body))
      assert request["state"]["log"] == long_state().log
      assert request["questions"]["billing"]["type"] == "noul"

      # A small body is not worth compressing.
      assert {:ok, _} = TypeSafe.system_one(client(url, compression: codec), "short", questions())
      assert_received {:request, headers, small}
      refute Map.has_key?(headers, "content-encoding")
      assert Jason.decode!(small)["state"] == "short"
    end
  end

  test "a call can turn compression on, or off" do
    url = serve([200, 200])

    assert {:ok, _} =
             TypeSafe.system_one(client(url), long_state(), questions(), compression: :gzip)

    assert_received {:request, %{"content-encoding" => "gzip"}, gzipped}
    assert Jason.decode!(:zlib.gunzip(gzipped))["state"]["log"] == long_state().log

    assert {:ok, _} =
             TypeSafe.system_one(client(url, compression: :gzip), long_state(), questions(),
               compression: false
             )

    assert_received {:request, headers, plain}
    refute Map.has_key?(headers, "content-encoding")
    assert Jason.decode!(plain)["state"]["log"] == long_state().log
  end

  test "a multipart body is compressed whole" do
    url = serve([200])
    photo = Image.from_binary!(@png)

    assert {:ok, _} =
             TypeSafe.system_one(client(url, compression: :gzip), %{photo: photo}, questions(),
               images: [photo]
             )

    assert_received {:request, headers, raw}
    assert headers["content-encoding"] == "gzip"
    assert headers["typesafe-danger-zone-images"] == "true"
    "multipart/form-data; boundary=" <> boundary = headers["content-type"]
    assert boundary =~ ~r/^typesafe-[0-9a-f]{32}$/

    multipart = :zlib.gunzip(raw)
    assert String.starts_with?(multipart, "--" <> boundary <> "\r\n")
    assert String.ends_with?(multipart, "\r\n--" <> boundary <> "--\r\n")
    assert multipart =~ ~s(name="request")
    assert multipart =~ ~s(name="image0"; filename="image0.png")
    assert :binary.match(multipart, @png) != :nomatch
    assert byte_size(raw) < byte_size(multipart) / 4
  end

  test "retries resend the same compressed bytes" do
    url = serve([529, 200])

    assert {:ok, _} =
             TypeSafe.system_one(client(url, compression: :gzip), long_state(), questions())

    assert_received {:request, %{"content-encoding" => "gzip"} = first_headers, first}
    assert_received {:request, %{"content-encoding" => "gzip"} = second_headers, second}
    assert first_headers["x-typesafe-retry-count"] == nil
    assert second_headers["x-typesafe-retry-count"] == "1"
    assert first == second
    assert Jason.decode!(:zlib.gunzip(second))["state"]["log"] == long_state().log
  end

  test "a bad compression option is rejected" do
    for bad <- [:brotli, "gzip", true] do
      assert_raise ArgumentError, ~r/:compression must be :gzip, :zstd or false/, fn ->
        client("http://localhost", compression: bad)
      end

      assert_raise ArgumentError, ~r/:compression must be/, fn ->
        TypeSafe.system_one(client("http://localhost:1"), long_state(), questions(),
          compression: bad
        )
      end
    end
  end
end
