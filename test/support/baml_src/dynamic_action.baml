class PluginAction {
  @@dynamic
}

function ChoosePluginAction(text: string) -> PluginAction {
  client Fireworks
  prompt #"
    Given the user query, choose the appropriate action.
    {{ ctx.output_format }}

    {{ _.role('user') }}
    {{ text }}
  "#
}
