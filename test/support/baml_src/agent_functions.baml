class LookupContact {
  type string @description("Always 'lookup_contact'")
  name string @description("Name of the contact to look up")
}

class Done {
  type string @description("Always 'done'")
  message string @description("Final response message to the user")
}

function ChooseTool(text: string) -> LookupContact | Done {
  client Ollama
  prompt #"
    Given the user query, determine the primary intent and select the appropriate tool to call.
    {{ ctx.output_format }}

    {{ _.role('user') }}
    {{ text }}
  "#
}
