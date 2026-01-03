client<llm> Ollama {
  provider "openai-generic"
  options {
    base_url "http://localhost:11434/v1"
    model "qwen3:1.7b"
  }
}
