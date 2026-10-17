defmodule TypeSafe.Image do
  @moduledoc """
  A PNG or JPEG to send with a call.

  An image goes into a request by its *reference*, a string that stands for it. Put
  the `TypeSafe.Image` where it belongs in the state or in a question, and pass it
  in the `:images` option of `TypeSafe.system_one/4`. It encodes to JSON as its
  reference and interpolates as it, so it can sit inside a map or a string:

      photo = TypeSafe.Image.from_file!("kitchen.jpg")

      TypeSafe.system_one(client, %{photo: photo}, %{
        mug: TypeSafe.box("The coffee mug in `photo`")
      }, model: "jev-1.14.0", images: [photo])

  Every use of a reference sends another copy of the image to the model, and images
  are billed as input tokens. They work with `jev-1.13.0` and `jev-1.14.0`.

  The API rejects what it can't use: a side shorter than 280 or longer than 1568
  pixels, a file over 16 MiB, or anything other than PNG and JPEG. It doesn't resize.
  Rotate the pixels upright first, because EXIF orientation is not applied.
  """

  @enforce_keys [:reference, :format, :binary]
  defstruct [:reference, :format, :binary]

  @type format :: :png | :jpeg
  @type t :: %__MODULE__{reference: String.t(), format: format(), binary: binary()}

  @prefix "typesafe-image-"
  @reference_regex ~r/typesafe-image-[0-9a-f]{32}/

  @doc """
  An image from the bytes of a PNG or JPEG file. Returns
  `{:error, :unsupported_format}` for anything else, such as GIF, WebP or HEIC.
  """
  @spec from_binary(binary()) :: {:ok, t()} | {:error, :unsupported_format}
  def from_binary(binary) when is_binary(binary) do
    case detect(binary) do
      nil -> {:error, :unsupported_format}
      format -> {:ok, %__MODULE__{reference: new_reference(), format: format, binary: binary}}
    end
  end

  @doc "Like `from_binary/1`, but returns the image or raises `ArgumentError`."
  @spec from_binary!(binary()) :: t()
  def from_binary!(binary) do
    case from_binary(binary) do
      {:ok, image} -> image
      {:error, :unsupported_format} -> raise ArgumentError, unsupported_message()
    end
  end

  @doc """
  An image read from a PNG or JPEG file. Returns `{:error, reason}` with a
  `File.read/1` reason, or `:unsupported_format`.
  """
  @spec from_file(Path.t()) :: {:ok, t()} | {:error, File.posix() | :unsupported_format}
  def from_file(path) do
    with {:ok, binary} <- File.read(path), do: from_binary(binary)
  end

  @doc "Like `from_file/1`, but returns the image or raises `ArgumentError`."
  @spec from_file!(Path.t()) :: t()
  def from_file!(path) do
    case from_file(path) do
      {:ok, image} ->
        image

      {:error, :unsupported_format} ->
        raise ArgumentError, "image #{path}: " <> unsupported_message()

      {:error, reason} ->
        raise ArgumentError, "could not read image #{path}: #{:file.format_error(reason)}"
    end
  end

  defp unsupported_message,
    do: "an image must be a PNG or JPEG file; convert GIF, WebP and HEIC first"

  defp detect(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: :png
  defp detect(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: :jpeg
  defp detect(_binary), do: nil

  defp new_reference, do: @prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  @doc false
  # Checks the images against the encoded request text. The API treats a reference
  # it was not given as plain text, answers a Box question about no image with a
  # box all the same, and rejects an image nothing refers to with an opaque 400, so
  # these mistakes are raised here instead. `text` is the state and questions as
  # JSON.
  def check_all!(images, text, box?) when is_list(images) do
    Enum.each(images, fn
      %__MODULE__{} -> :ok
      other -> raise ArgumentError, ":images must hold TypeSafe.Image, got: #{inspect(other)}"
    end)

    images = Enum.uniq_by(images, & &1.reference)
    attached = MapSet.new(images, & &1.reference)

    case Enum.find(Regex.scan(@reference_regex, text), fn [ref] -> ref not in attached end) do
      [reference] ->
        raise ArgumentError,
              "#{reference} refers to an image that is not attached: pass it in :images"

      nil ->
        :ok
    end

    if images == [] and box? do
      raise ArgumentError, "a Box question needs an image: pass one in :images"
    end

    Enum.each(images, fn %{reference: reference} ->
      unless String.contains?(text, reference) do
        raise ArgumentError,
              "image #{reference} is attached but nothing in the state or questions refers to it"
      end
    end)

    images
  end

  def check_all!(other, _text, _box?) do
    raise ArgumentError, ":images must be a list of TypeSafe.Image, got: #{inspect(other)}"
  end

  @doc false
  def part_name(index), do: "image#{index}"

  @doc false
  def extension(%__MODULE__{format: :png}), do: "png"
  def extension(%__MODULE__{format: :jpeg}), do: "jpg"

  @doc false
  def content_type(%__MODULE__{format: :png}), do: "image/png"
  def content_type(%__MODULE__{format: :jpeg}), do: "image/jpeg"

  defimpl String.Chars do
    def to_string(%{reference: reference}), do: reference
  end

  defimpl Jason.Encoder do
    def encode(%{reference: reference}, opts), do: Jason.Encode.string(reference, opts)
  end

  defimpl Inspect do
    def inspect(%{reference: reference, format: format, binary: binary}, _opts) do
      "#TypeSafe.Image<#{format}, #{byte_size(binary)} bytes, #{reference}>"
    end
  end
end
