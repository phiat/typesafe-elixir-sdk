defmodule TypeSafe.ImagesTest do
  use ExUnit.Case, async: true

  alias TypeSafe.{BoxAnswer, Error, Image}

  setup {Req.Test, :verify_on_exit!}

  @fixtures Path.expand("fixtures", __DIR__)
  @png <<0x89, "PNG\r\n", 0x1A, "\n", "not really pixels">>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, "not really pixels">>

  defp client(opts \\ []) do
    [
      api_key: "test-key",
      retry: [backoff_initial: 0],
      req_options: [plug: {Req.Test, __MODULE__}, retry_log_level: false]
    ]
    |> Keyword.merge(opts)
    |> TypeSafe.new()
  end

  defp rectangle(photo) do
    %{
      present: TypeSafe.noul("Is there a red rectangle in `photo`?"),
      rect: TypeSafe.box("The red rectangle in #{photo}")
    }
  end

  defp rectangle_answers(overrides \\ %{}) do
    %{
      "model" => "jev-1.14.0",
      "answers" => %{
        "present" => %{"type" => "noul", "noul" => 0.97},
        "rect" =>
          Map.merge(
            %{
              "type" => "box",
              "box" => %{"top" => 0.14, "bottom" => 0.52, "left" => 0.5, "right" => 0.91},
              "confidence" => 0.95
            },
            overrides
          )
      },
      "usage" => %{"input_tokens" => 755, "output_tokens" => 36}
    }
  end

  # The multipart body, as Plug parses it: the request JSON, and each file part as
  # a %Plug.Upload{}.
  defp read_multipart(conn) do
    conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart]))
    {conn.body_params, conn}
  end

  defp respond(conn, status, body) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  describe "TypeSafe.Image" do
    test "detects PNG and JPEG" do
      assert {:ok, %Image{format: :png}} = Image.from_binary(@png)
      assert {:ok, %Image{format: :jpeg}} = Image.from_binary(@jpeg)

      for not_an_image <- ["GIF89a", "RIFF....WEBP", "", "hello"] do
        assert {:error, :unsupported_format} = Image.from_binary(not_an_image)
      end

      assert_raise ArgumentError, ~r/PNG or JPEG/, fn -> Image.from_binary!("hello") end
    end

    test "reads files, and names the file in errors" do
      assert %Image{format: :png} = Image.from_file!(Path.join(@fixtures, "red-rectangle.png"))
      assert %Image{format: :jpeg} = Image.from_file!(Path.join(@fixtures, "red-rectangle.jpg"))
      assert {:error, :enoent} = Image.from_file("/no/such/photo.png")
      assert {:error, :unsupported_format} = Image.from_file(__ENV__.file)

      assert_raise ArgumentError, ~r{could not read image /no/such/photo.png}, fn ->
        Image.from_file!("/no/such/photo.png")
      end

      assert_raise ArgumentError, ~r/images_test.exs: an image must be a PNG or JPEG/, fn ->
        Image.from_file!(__ENV__.file)
      end
    end

    test "a reference is unique, and the image encodes and interpolates as it" do
      {a, b} = {Image.from_binary!(@png), Image.from_binary!(@png)}

      assert a.reference != b.reference
      assert a.reference =~ ~r/^typesafe-image-[0-9a-f]{32}$/
      assert "#{a}" == a.reference
      assert Jason.encode!(%{photo: a}) == ~s({"photo":"#{a.reference}"})
    end

    test "inspect leaves the bytes out" do
      shown = inspect(Image.from_binary!(@png))
      assert shown =~ ~r/^#TypeSafe.Image<png, 25 bytes, typesafe-image-/
      refute shown =~ "pixels"
    end
  end

  describe "system_one/4 with images" do
    test "sends a multipart upload with the images header" do
      test = self()
      {mug, badge} = {Image.from_binary!(@png), Image.from_binary!(@jpeg)}

      Req.Test.expect(__MODULE__, fn conn ->
        {parts, conn} = read_multipart(conn)
        send(test, {:request, conn, parts})
        respond(conn, 200, rectangle_answers())
      end)

      assert {:ok, response} =
               TypeSafe.system_one(
                 client(),
                 %{photo: mug},
                 %{
                   present: TypeSafe.noul("Is there a red rectangle in `photo`?"),
                   rect: TypeSafe.box("The red rectangle in `photo`, or the person in #{badge}")
                 },
                 model: "jev-1.14.0",
                 images: [mug, badge]
               )

      assert response.model == "jev-1.14.0"
      assert_received {:request, conn, parts}

      assert Plug.Conn.get_req_header(conn, "typesafe-danger-zone-images") == ["true"]
      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type =~ ~r"^multipart/form-data; boundary="
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

      request = Jason.decode!(parts["request"])
      assert request["model"] == "jev-1.14.0"
      assert request["state"] == %{"photo" => mug.reference}
      assert request["questions"]["rect"]["type"] == "box"

      assert request["assets"] == %{
               mug.reference => %{"type" => "image", "part" => "image0"},
               badge.reference => %{"type" => "image", "part" => "image1"}
             }

      assert %Plug.Upload{filename: "image0.png", content_type: "image/png"} = parts["image0"]
      assert File.read!(parts["image0"].path) == @png
      assert %Plug.Upload{filename: "image1.jpg", content_type: "image/jpeg"} = parts["image1"]
      assert File.read!(parts["image1"].path) == @jpeg
    end

    test "an image listed twice is sent once" do
      test = self()
      mug = Image.from_binary!(@png)

      Req.Test.expect(__MODULE__, fn conn ->
        {parts, conn} = read_multipart(conn)
        send(test, {:parts, parts})
        respond(conn, 200, rectangle_answers())
      end)

      TypeSafe.system_one!(client(), %{photo: mug}, rectangle(mug), images: [mug, mug])
      assert_received {:parts, parts}
      assert parts |> Map.keys() |> Enum.sort() == ["image0", "request"]
    end

    test "a call without images is plain JSON with no images header" do
      test = self()

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, conn, Jason.decode!(raw)})
        respond(conn, 200, %{"model" => "m", "answers" => %{}, "usage" => usage()})
      end)

      TypeSafe.system_one(client(), "text", %{q: TypeSafe.noul("Is it?")})
      assert_received {:request, conn, body}

      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "typesafe-danger-zone-images") == []
      refute Map.has_key?(body, "assets")
    end

    test "extra_body assets pass through when no image is attached" do
      test = self()

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:body, Jason.decode!(raw)})
        respond(conn, 200, %{"model" => "m", "answers" => %{}, "usage" => usage()})
      end)

      TypeSafe.system_one(client(), "text", %{q: TypeSafe.noul("Is it?")},
        extra_body: %{assets: %{"raw" => 1}}
      )

      assert_received {:body, %{"assets" => %{"raw" => 1}}}
    end

    test "retries resend the whole upload" do
      test = self()
      mug = Image.from_binary!(@png)

      Req.Test.expect(__MODULE__, &respond(&1, 529, %{"error" => "Overloaded"}))

      Req.Test.expect(__MODULE__, fn conn ->
        {parts, conn} = read_multipart(conn)
        send(test, {:retry, Plug.Conn.get_req_header(conn, "x-typesafe-retry-count"), parts})
        respond(conn, 200, rectangle_answers())
      end)

      assert {:ok, _} =
               TypeSafe.system_one(client(), %{photo: mug}, rectangle(mug), images: [mug])

      assert_received {:retry, ["1"], parts}
      assert File.read!(parts["image0"].path) == @png
    end

    test "mistakes the API handles badly are raised before sending" do
      mug = Image.from_binary!(@png)
      other = Image.from_binary!(@png)
      box = %{rect: TypeSafe.box("The mug in `photo`")}

      # A Box question about no image gets a junk box from the API.
      assert_raise ArgumentError, ~r/needs an image/, fn ->
        TypeSafe.system_one(client(), %{photo: "x"}, box)
      end

      # An attached image nothing refers to.
      assert_raise ArgumentError, ~r/nothing in the state or questions refers to it/, fn ->
        TypeSafe.system_one(client(), %{photo: "x"}, box, images: [mug])
      end

      # A reference whose image was never attached would be read as text.
      error =
        assert_raise ArgumentError, ~r/not attached/, fn ->
          TypeSafe.system_one(client(), %{photo: mug}, box)
        end

      assert error.message =~ mug.reference

      error =
        assert_raise ArgumentError, ~r/not attached/, fn ->
          TypeSafe.system_one(client(), %{photo: mug, badge: other}, box, images: [mug])
        end

      assert error.message =~ other.reference

      assert_raise ArgumentError, ~r/:images must hold TypeSafe.Image/, fn ->
        TypeSafe.system_one(client(), "text", box, images: ["photo.png"])
      end
    end
  end

  describe "long context" do
    test "sets its header, and the caller's headers win" do
      test = self()

      Req.Test.expect(__MODULE__, fn conn ->
        send(test, {:header, Plug.Conn.get_req_header(conn, "typesafe-danger-zone-long-context")})
        respond(conn, 200, %{"model" => "m", "answers" => %{}, "usage" => usage()})
      end)

      TypeSafe.system_one(client(), "text", %{q: TypeSafe.noul("Is it?")}, long_context: true)
      assert_received {:header, ["true"]}

      Req.Test.expect(__MODULE__, fn conn ->
        send(test, {:header, Plug.Conn.get_req_header(conn, "typesafe-danger-zone-long-context")})
        respond(conn, 200, %{"model" => "m", "answers" => %{}, "usage" => usage()})
      end)

      TypeSafe.system_one(client(), "text", %{q: TypeSafe.noul("Is it?")},
        long_context: true,
        headers: %{"TypeSafe-Danger-Zone-Long-Context" => "false"}
      )

      assert_received {:header, ["false"]}
    end
  end

  describe "box answers" do
    setup do
      mug = Image.from_binary!(@png)
      %{mug: mug}
    end

    test "decode into a BoxAnswer", %{mug: mug} do
      Req.Test.expect(__MODULE__, &respond(&1, 200, rectangle_answers()))

      assert {:ok, response} =
               TypeSafe.system_one(client(), %{photo: mug}, rectangle(mug), images: [mug])

      assert %BoxAnswer{top: 0.14, bottom: 0.52, left: 0.5, right: 0.91, confidence: 0.95} =
               response.answers.rect

      assert {left, top, right, bottom} = BoxAnswer.pixels(response.answers.rect, 200, 100)
      assert_in_delta left, 100.0, 1.0e-9
      assert_in_delta top, 14.0, 1.0e-9
      assert_in_delta right, 182.0, 1.0e-9
      assert_in_delta bottom, 52.0, 1.0e-9
    end

    test "the confidence may be null or left out", %{mug: mug} do
      null = rectangle_answers(%{"confidence" => nil})

      left_out =
        update_in(rectangle_answers(), ["answers", "rect"], &Map.delete(&1, "confidence"))

      refute Map.has_key?(left_out["answers"]["rect"], "confidence")
      assert Map.fetch!(null["answers"]["rect"], "confidence") == nil

      for body <- [null, left_out] do
        Req.Test.expect(__MODULE__, &respond(&1, 200, body))

        assert {:ok, response} =
                 TypeSafe.system_one(client(), %{photo: mug}, rectangle(mug), images: [mug])

        assert response.answers.rect.confidence == nil
      end
    end

    test "a bad answer names the field", %{mug: mug} do
      for {overrides, field} <- [
            {%{"box" => %{"top" => 0.1, "bottom" => 0.2, "left" => 0.1}},
             "answers.rect.box.right"},
            {%{"box" => "here"}, "answers.rect.box"},
            {%{"confidence" => "high"}, "answers.rect.confidence"},
            {%{"type" => "noul"}, "answers.rect.type"}
          ] do
        Req.Test.expect(__MODULE__, &respond(&1, 200, rectangle_answers(overrides)))

        assert {:error, %Error{reason: :invalid_response, message: message}} =
                 TypeSafe.system_one(client(), %{photo: mug}, rectangle(mug), images: [mug])

        assert message =~ field
      end
    end
  end

  describe "limits and errors" do
    test "a Choice takes at most 255 options and a Score 10 levels" do
      assert %TypeSafe.Choice{} = TypeSafe.choice("Which?", Enum.map(1..255, &"o#{&1}"))
      assert %TypeSafe.Score{} = TypeSafe.score("How?", Enum.map(1..10, &"l#{&1}"))

      assert_raise ArgumentError, ~r/at most 255 options, got: 256/, fn ->
        TypeSafe.choice("Which?", Enum.map(1..256, &"o#{&1}"))
      end

      assert_raise ArgumentError, ~r/at most 10 levels, got: 11/, fn ->
        TypeSafe.score("How?", Enum.map(1..11, &"l#{&1}"))
      end

      assert_raise ArgumentError, ~r/instructions/, fn -> TypeSafe.box("  ") end
    end

    test "a 413 is a payload_too_large error" do
      Req.Test.expect(__MODULE__, fn conn ->
        respond(conn, 413, %{"detail" => %{"message" => "Request too large."}})
      end)

      assert {:error,
              %Error{reason: :payload_too_large, status: 413, message: "Request too large."}} =
               TypeSafe.system_one(client(), "text", %{q: TypeSafe.noul("Is it?")})
    end
  end

  defp usage, do: %{"input_tokens" => 1, "output_tokens" => 1}
end
