class Person {
  name string
  age int?
  occupation string?
}

function ExtractPerson(text: string) -> Person {
  client Fireworks
  prompt #"
    Extract the person's name, age, and occupation from this text.
    {{ ctx.output_format }}

    ---
    Text: {{ text }}
  "#
}

function Summarize(text: string) -> string {
  client Fireworks
  prompt #"
    Summarize the following text in one sentence.
    {{ ctx.output_format }}

    ---
    Text: {{ text }}
  "#
}

function Classify(text: string) -> string {
  client Fireworks
  prompt #"
    Classify the sentiment of this text as one of: positive, negative, or neutral.
    {{ ctx.output_format }}

    ---
    Text: {{ text }}
  "#
}

function Chat(text: string) -> string {
  client Fireworks
  prompt #"
    {{ ctx.output_format }}

    {{ text }}
  "#
}

