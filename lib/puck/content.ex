defmodule Puck.Content do
  @moduledoc """
  Multi-modal content for messages.

  ## Types

  - `text/1` - Plain text
  - `image_url/1` - Image from URL
  - `image/2` - Binary image data
  - `file/2` - Files (PDF, CSV, etc.)
  - `audio/2`, `video/2` - Media content

  ## Examples

      alias Puck.Content

      Content.text("What's in this image?")
      Content.image_url("https://example.com/cat.png")
      Content.image(image_bytes, "image/png")
      Content.file(pdf_bytes, "application/pdf", filename: "report.pdf")

      # Multi-modal call
      {:ok, response, _ctx} = Puck.call([
        Content.text("Describe this"),
        Content.image_url("https://example.com/photo.png")
      ], model: "anthropic:claude-sonnet-4-5")

  """

  defmodule Part do
    @moduledoc """
    A single content part within a message.

    This is the core struct that represents any type of content.
    Use the factory functions in `Puck.Content` to create parts.
    """

    @type content_type :: :text | :image_url | :image | :file | :audio | :video

    @type t :: %__MODULE__{
            type: content_type(),
            text: String.t() | nil,
            url: String.t() | nil,
            data: binary() | nil,
            media_type: String.t() | nil,
            filename: String.t() | nil,
            metadata: map()
          }

    @enforce_keys [:type]
    defstruct type: nil,
              text: nil,
              url: nil,
              data: nil,
              media_type: nil,
              filename: nil,
              metadata: %{}

    defimpl Inspect do
      def inspect(%{type: type} = part, opts) do
        Inspect.Algebra.concat([
          "#Content.Part<",
          Inspect.Algebra.to_doc(type, opts),
          " ",
          describe(part),
          ">"
        ])
      end

      defp describe(%{type: :text, text: text}), do: inspect_text(text)
      defp describe(%{type: :image_url, url: url}), do: "url: #{url}"

      defp describe(%{type: :file} = p),
        do: "#{p.media_type} #{p.filename || ""} (#{data_size(p)} bytes)"

      defp describe(%{type: type} = p) when type in [:image, :audio, :video],
        do: "#{p.media_type} (#{data_size(p)} bytes)"

      defp describe(_), do: "unknown"

      defp data_size(%{data: nil}), do: 0
      defp data_size(%{data: data}), do: byte_size(data)

      defp inspect_text(nil), do: "nil"
      defp inspect_text(text) when byte_size(text) > 40, do: "\"#{String.slice(text, 0, 40)}...\""
      defp inspect_text(text), do: "\"#{text}\""
    end
  end

  alias Puck.Content.Wrappable

  @doc """
  Creates a text content part.

  ## Examples

      Content.text("Hello, world!")
      Content.text("Analyze this", %{cache: true})

  """
  @spec text(String.t(), map()) :: Part.t()
  def text(content, metadata \\ %{}) when is_binary(content) do
    %Part{type: :text, text: content, metadata: metadata}
  end

  @doc """
  Creates an image URL content part.

  ## Examples

      Content.image_url("https://example.com/photo.jpg")

  """
  @spec image_url(String.t(), map()) :: Part.t()
  def image_url(url, metadata \\ %{}) when is_binary(url) do
    %Part{type: :image_url, url: url, metadata: metadata}
  end

  @doc """
  Creates an image content part from binary data.

  The data should be the raw binary image bytes (not base64 encoded).
  Encoding is handled by the backend adapter.

  ## Examples

      bytes = File.read!("photo.png")
      Content.image(bytes, "image/png")

  """
  @spec image(binary(), String.t(), map()) :: Part.t()
  def image(data, media_type \\ "image/png", metadata \\ %{}) when is_binary(data) do
    %Part{type: :image, data: data, media_type: media_type, metadata: metadata}
  end

  @doc """
  Creates a file content part.

  Supports any file type - PDFs, CSVs, documents, etc.
  The data should be raw binary bytes.

  ## Options

  - `:filename` - Optional filename for the file

  ## Examples

      pdf_bytes = File.read!("report.pdf")
      Content.file(pdf_bytes, "application/pdf")
      Content.file(pdf_bytes, "application/pdf", filename: "report.pdf")

      csv_bytes = File.read!("data.csv")
      Content.file(csv_bytes, "text/csv", filename: "data.csv")

  """
  @spec file(binary(), String.t(), keyword()) :: Part.t()
  def file(data, media_type, opts \\ []) when is_binary(data) do
    %Part{
      type: :file,
      data: data,
      media_type: media_type,
      filename: Keyword.get(opts, :filename),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Creates an audio content part.

  ## Examples

      audio_bytes = File.read!("speech.mp3")
      Content.audio(audio_bytes, "audio/mp3")

  """
  @spec audio(binary(), String.t(), map()) :: Part.t()
  def audio(data, media_type \\ "audio/wav", metadata \\ %{}) when is_binary(data) do
    %Part{type: :audio, data: data, media_type: media_type, metadata: metadata}
  end

  @doc """
  Creates a video content part.

  ## Examples

      video_bytes = File.read!("clip.mp4")
      Content.video(video_bytes, "video/mp4")

  """
  @spec video(binary(), String.t(), map()) :: Part.t()
  def video(data, media_type \\ "video/mp4", metadata \\ %{}) when is_binary(data) do
    %Part{type: :video, data: data, media_type: media_type, metadata: metadata}
  end

  @doc """
  Creates a generic content part with custom type.

  Use this for provider-specific content types not covered by the
  standard factory functions.

  ## Examples

      Content.new(:thinking, text: "Let me think about this...")
      Content.new(:tool_result, text: "42", metadata: %{tool_id: "calc_1"})

  """
  @spec new(atom(), keyword()) :: Part.t()
  def new(type, fields \\ []) when is_atom(type) do
    struct!(Part, Keyword.put(fields, :type, type))
  end

  @doc """
  Wraps content into a list of Content.Part structs.

  Delegates to the `Puck.Content.Wrappable` protocol, which handles:
  - Strings → text parts
  - Part structs → wrapped in list
  - Lists of parts → pass through unchanged
  - Maps/structs → JSON-encoded into text parts

  Maps and structs are JSON-encoded to support tool results and structured
  data in multi-turn conversations. When a backend returns structured data
  like `%{result: 42}` or a struct, this is serialized so the LLM can read it.

  ## Customizing Behavior

  Implement the `Puck.Content.Wrappable` protocol for custom types:

      defimpl Puck.Content.Wrappable, for: MyApp.CustomType do
        def wrap(value), do: [Puck.Content.text(to_string(value))]
      end

  ## Examples

      Content.wrap("Hello")
      #=> [%Part{type: :text, text: "Hello"}]

      Content.wrap(Content.text("Hi"))
      #=> [%Part{type: :text, text: "Hi"}]

      Content.wrap([Content.text("Hi"), Content.image_url("...")])
      #=> [%Part{...}, %Part{...}]

      # Maps are JSON-encoded (for tool results, structured data)
      Content.wrap(%{result: 42, status: "success"})
      #=> [%Part{type: :text, text: "{\"result\":42,\"status\":\"success\"}"}]

      # Structs are also JSON-encoded
      Content.wrap(%MyApp.Person{name: "Alice", age: 30})
      #=> [%Part{type: :text, text: "{\"name\":\"Alice\",\"age\":30}"}]

  """
  @spec wrap(term()) :: [Part.t()]
  def wrap(content), do: Wrappable.wrap(content)
end
