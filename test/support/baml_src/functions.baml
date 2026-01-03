class Person {
  name string
  age int?
}

function ExtractPerson(text: string) -> Person {
  client Ollama
  prompt #"
    Extract the person's name and age from this text.
    Return a JSON object with "name" (string) and "age" (number or null).

    Text: {{ text }}

    Respond with only valid JSON, no explanation.
  "#
}

function Summarize(text: string) -> string {
  client Ollama
  prompt #"
    Summarize the following text in one sentence.

    Text: {{ text }}
  "#
}

function Classify(text: string) -> string {
  client Ollama
  prompt #"
    Classify the sentiment of this text as one of: positive, negative, or neutral.
    Respond with only the classification word.

    Text: {{ text }}
  "#
}
