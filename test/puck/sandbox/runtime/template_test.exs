defmodule Puck.Sandbox.Runtime.TemplateTest do
  use ExUnit.Case, async: true

  alias Puck.Sandbox.Runtime
  alias Puck.Sandbox.Runtime.Adapters.Test, as: TestAdapter
  alias Puck.Sandbox.Runtime.Instance
  alias Puck.Sandbox.Runtime.Template

  setup do
    name = :"test_adapter_#{System.unique_integer([:positive])}"
    start_supervised!({TestAdapter, name: name})
    {:ok, agent_name: name}
  end

  describe "new/1" do
    test "creates template with keyword syntax", %{agent_name: agent_name} do
      template =
        Template.new(
          adapter: TestAdapter,
          config: %{agent_name: agent_name, image: "alpine", memory_mb: 256}
        )

      assert template.adapter == TestAdapter
      assert template.config == %{agent_name: agent_name, image: "alpine", memory_mb: 256}
    end

    test "creates template with tuple syntax (map config)", %{agent_name: agent_name} do
      template =
        Template.new({TestAdapter, %{agent_name: agent_name, image: "alpine", memory_mb: 256}})

      assert template.adapter == TestAdapter
      assert template.config == %{agent_name: agent_name, image: "alpine", memory_mb: 256}
    end
  end

  describe "merge/2" do
    test "merges overrides into template config" do
      template = Template.new({TestAdapter, %{image: "python", memory_mb: 256}})

      merged = Template.merge(template, %{memory_mb: 512, cpu: 2})

      assert merged == %{image: "python", memory_mb: 512, cpu: 2}
    end
  end

  describe "to_backend/2" do
    test "returns tuple for Runtime.create/1" do
      template = Template.new({TestAdapter, %{image: "alpine"}})

      assert {TestAdapter, %{image: "alpine"}} = Template.to_backend(template)
    end
  end

  describe "Runtime.create/2 with Template" do
    test "creates sandbox from template", %{agent_name: agent_name} do
      template = Template.new({TestAdapter, %{agent_name: agent_name, image: "test:latest"}})

      {:ok, sandbox} = Runtime.create(template)

      assert %Instance{} = sandbox
      assert sandbox.adapter == TestAdapter
      assert sandbox.config == %{agent_name: agent_name, image: "test:latest"}
      assert Runtime.status(sandbox) == :running
    end
  end
end
