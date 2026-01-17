Logger.configure(level: :warning)
ExUnit.start(exclude: [:integration, :docker, :baml, :claude_agent_sdk])
