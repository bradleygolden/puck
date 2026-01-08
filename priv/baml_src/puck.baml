// Built-in BAML functions shipped with Puck.
// Override PuckClient via client_registry: %{"PuckClient" => "YourClient"}
client<llm> PuckClient {
  provider "openai-generic"
  options {
    base_url "http://localhost:11434/v1"
    model "qwen3:4b"
  }
}

function PuckSummarize(text: string, instructions: string) -> string {
  client PuckClient
  prompt #"
    {{ _.role("system") }}
    {{ instructions }}

    {{ _.role("user") }}
    {{ text }}
  "#
}
