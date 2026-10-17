defmodule TypeSafe.Body do
  @moduledoc false
  # Encodes a request body and, if asked, compresses it.
  #
  # The body is built here and handed to Req as final bytes, not as Req's `:json`
  # or `:form_multipart` options. Req re-runs its request steps on a retry, which
  # would encode again and could leave a compressed header on an uncompressed body.
  # Final bytes are sent as they are, every attempt.

  # Bodies shorter than this are sent as they are, as the official SDKs do.
  @min_compressed_body 1024

  @doc """
  Validates a `:compression` option: `:gzip`, `:zstd` or `false`.
  """
  def check_compression!(compression) when compression in [false, nil], do: false
  def check_compression!(:gzip), do: :gzip

  def check_compression!(:zstd) do
    if Code.ensure_loaded?(:zstd) and function_exported?(:zstd, :compress, 1) do
      :zstd
    else
      raise ArgumentError, "compression: :zstd needs Erlang/OTP 28 or later; use :gzip"
    end
  end

  def check_compression!(other) do
    raise ArgumentError, ":compression must be :gzip, :zstd or false, got: #{inspect(other)}"
  end

  @doc """
  Encodes `body`, a map, as JSON, or as `multipart/form-data` when there are
  `files`: the request JSON first, then one file part each. Returns `nil` for no
  body, or `%{data: iodata, content_type: String.t(), content_encoding: String.t() | nil}`.

  A file is `%{name:, filename:, content_type:, data:}`.
  """
  def encode(nil, _files, _compression), do: nil

  def encode(body, files, compression) do
    json = Jason.encode_to_iodata!(body)

    {data, content_type} =
      if files in [nil, []], do: {json, "application/json"}, else: multipart(json, files)

    {data, content_encoding} = compress(data, compression)
    %{data: data, content_type: content_type, content_encoding: content_encoding}
  end

  defp multipart(json, files) do
    boundary = "typesafe-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    request = [
      "--",
      boundary,
      "\r\nContent-Disposition: form-data; name=\"request\"\r\n",
      "Content-Type: application/json\r\n\r\n",
      json
    ]

    parts =
      for %{name: name, filename: filename, content_type: content_type, data: data} <- files do
        [
          "\r\n--",
          boundary,
          "\r\nContent-Disposition: form-data; name=\"",
          name,
          "\"; filename=\"",
          filename,
          "\"\r\nContent-Type: ",
          content_type,
          "\r\n\r\n",
          data
        ]
      end

    {[request, parts, "\r\n--", boundary, "--\r\n"], "multipart/form-data; boundary=" <> boundary}
  end

  defp compress(data, false), do: {data, nil}

  defp compress(data, codec) do
    if IO.iodata_length(data) < @min_compressed_body do
      {data, nil}
    else
      binary = IO.iodata_to_binary(data)

      case codec do
        :gzip -> {:zlib.gzip(binary), "gzip"}
        # `apply/3`: `:zstd` is OTP 28+, and a direct call would warn on older ones.
        :zstd -> {apply(:zstd, :compress, [binary]), "zstd"}
      end
    end
  end
end
