client<llm> Fireworks {
  provider "openai-generic"
  options {
    base_url "https://api.fireworks.ai/inference/v1"
    model "accounts/fireworks/models/glm-4p7"
    api_key env.FIREWORKS_API_KEY
    stream_options {
      include_usage true
    }
  }
}
