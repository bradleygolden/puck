Logger.configure(level: :warning)
ExUnit.start(exclude: [:integration, :docker, :baml, :claude_agent_sdk])

if Code.ensure_loaded?(ClaudeAgentSDK) do
  Mimic.copy(ClaudeAgentSDK)
end

if Code.ensure_loaded?(BamlElixir.Client) do
  Mimic.copy(BamlElixir.Client)
end
