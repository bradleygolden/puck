Logger.configure(level: :warning)
Puck.Test.start_link()
ExUnit.start(exclude: [:integration, :docker, :baml, :claude_agent_sdk])
