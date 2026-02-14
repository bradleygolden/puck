if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Puck.Backends.Baml.TypeBuilderTest do
    use ExUnit.Case, async: true

    alias BamlElixir.TypeBuilder, as: TB
    alias Puck.Backends.Baml.TypeBuilder

    describe "from_schema/2 with simple object" do
      test "converts object to a single Class with typed Fields" do
        schema = Zoi.object(%{name: Zoi.string(), age: Zoi.integer(), active: Zoi.boolean()})

        assert [%TB.Class{name: "DynamicOutput", fields: fields}] =
                 TypeBuilder.from_schema(schema)

        assert [
                 %TB.Field{name: "active", type: "bool"},
                 %TB.Field{name: "age", type: "int"},
                 %TB.Field{name: "name", type: "string"}
               ] = fields
      end

      test "maps float type to BAML float" do
        schema = Zoi.object(%{score: Zoi.float()})

        [%TB.Class{fields: [%TB.Field{name: "score", type: "float"}]}] =
          TypeBuilder.from_schema(schema)
      end

      test "maps number type to BAML float" do
        schema = Zoi.object(%{value: Zoi.number()})

        [%TB.Class{fields: [%TB.Field{name: "value", type: "float"}]}] =
          TypeBuilder.from_schema(schema)
      end
    end

    describe "from_schema/2 with nested objects" do
      test "produces multiple Classes with proper names" do
        schema =
          Zoi.object(%{
            name: Zoi.string(),
            address: Zoi.object(%{street: Zoi.string(), city: Zoi.string()})
          })

        types = TypeBuilder.from_schema(schema)
        assert length(types) == 2

        address_class = Enum.find(types, &(&1.name == "DynamicOutputAddress"))
        root_class = Enum.find(types, &(&1.name == "DynamicOutput"))

        assert %TB.Class{fields: address_fields} = address_class
        assert Enum.any?(address_fields, &(&1.name == "street" and &1.type == "string"))
        assert Enum.any?(address_fields, &(&1.name == "city" and &1.type == "string"))

        assert %TB.Class{fields: root_fields} = root_class
        address_field = Enum.find(root_fields, &(&1.name == "address"))
        assert address_field.type == "DynamicOutputAddress"
      end

      test "handles deeply nested objects" do
        schema =
          Zoi.object(%{
            level1:
              Zoi.object(%{
                level2: Zoi.object(%{value: Zoi.string()})
              })
          })

        types = TypeBuilder.from_schema(schema)
        assert length(types) == 3

        assert Enum.any?(types, &(&1.name == "DynamicOutputLevel1Level2"))
        assert Enum.any?(types, &(&1.name == "DynamicOutputLevel1"))
        assert Enum.any?(types, &(&1.name == "DynamicOutput"))
      end
    end

    describe "from_schema/2 with enums" do
      test "converts string enums to Enum with EnumValues" do
        schema = Zoi.object(%{status: Zoi.enum([:active, :inactive, :pending])})
        types = TypeBuilder.from_schema(schema)

        enum_type = Enum.find(types, &match?(%TB.Enum{}, &1))
        assert %TB.Enum{name: "DynamicOutputStatus", values: values} = enum_type
        value_strings = Enum.map(values, & &1.value)
        assert "active" in value_strings
        assert "inactive" in value_strings
        assert "pending" in value_strings
      end

      test "references enum by name in the parent Class field" do
        schema = Zoi.object(%{status: Zoi.enum([:active, :inactive])})
        types = TypeBuilder.from_schema(schema)

        root_class = Enum.find(types, &(&1.name == "DynamicOutput"))
        status_field = Enum.find(root_class.fields, &(&1.name == "status"))
        assert status_field.type == "DynamicOutputStatus"
      end
    end

    describe "from_schema/2 with arrays" do
      test "converts arrays to Fields with List type" do
        schema = Zoi.object(%{tags: Zoi.array(Zoi.string())})

        [%TB.Class{fields: [%TB.Field{name: "tags", type: type}]}] =
          TypeBuilder.from_schema(schema)

        assert %TB.List{type: "string"} = type
      end

      test "handles arrays of objects" do
        schema =
          Zoi.object(%{
            items: Zoi.array(Zoi.object(%{name: Zoi.string()}))
          })

        types = TypeBuilder.from_schema(schema)

        root_class = Enum.find(types, &(&1.name == "DynamicOutput"))
        items_field = Enum.find(root_class.fields, &(&1.name == "items"))
        assert %TB.List{type: "DynamicOutputItems"} = items_field.type

        items_class = Enum.find(types, &(&1.name == "DynamicOutputItems"))
        assert %TB.Class{} = items_class
      end

      test "handles arrays of integers" do
        schema = Zoi.object(%{scores: Zoi.array(Zoi.integer())})

        [%TB.Class{fields: [%TB.Field{name: "scores", type: type}]}] =
          TypeBuilder.from_schema(schema)

        assert %TB.List{type: "int"} = type
      end
    end

    describe "from_schema/2 with nullable fields" do
      test "appends ? suffix for nullable primitive types" do
        schema = Zoi.object(%{nickname: Zoi.string() |> Zoi.nullable()})

        [%TB.Class{fields: [%TB.Field{name: "nickname", type: "string?"}]}] =
          TypeBuilder.from_schema(schema)
      end

      test "appends ? suffix for nullable object types" do
        schema =
          Zoi.object(%{
            address: Zoi.object(%{city: Zoi.string()}) |> Zoi.nullable()
          })

        types = TypeBuilder.from_schema(schema)
        root_class = Enum.find(types, &(&1.name == "DynamicOutput"))
        address_field = Enum.find(root_class.fields, &(&1.name == "address"))
        assert "DynamicOutputAddress?" = address_field.type
      end

      test "makes optional (non-required) fields nullable" do
        schema = Zoi.object(%{nickname: Zoi.string() |> Zoi.optional()})

        [%TB.Class{fields: [%TB.Field{name: "nickname", type: "string?"}]}] =
          TypeBuilder.from_schema(schema)
      end

      test "does not double-nullable fields that are both optional and nullable" do
        schema = Zoi.object(%{nickname: Zoi.string() |> Zoi.nullable() |> Zoi.optional()})

        [%TB.Class{fields: [%TB.Field{name: "nickname", type: "string?"}]}] =
          TypeBuilder.from_schema(schema)
      end
    end

    describe "from_schema/2 with unions (anyOf)" do
      test "converts multi-type unions to Union struct" do
        schema =
          Zoi.object(%{
            value: Zoi.union([Zoi.string(), Zoi.integer()])
          })

        [%TB.Class{fields: [%TB.Field{name: "value", type: type}]}] =
          TypeBuilder.from_schema(schema)

        assert %TB.Union{types: ["string", "int"]} = type
      end

      test "converts tagged union of objects to named classes derived from discriminator" do
        schema =
          Zoi.union([
            Zoi.object(%{type: Zoi.literal("a"), name: Zoi.string()}),
            Zoi.object(%{type: Zoi.literal("b"), count: Zoi.integer()})
          ])

        types = TypeBuilder.from_schema(schema)

        class_names = Enum.filter(types, &match?(%TB.Class{}, &1)) |> Enum.map(& &1.name)
        assert "DynamicOutputA" in class_names
        assert "DynamicOutputB" in class_names

        root_union = Enum.find(types, &match?(%TB.Union{name: "DynamicOutput"}, &1))
        assert %TB.Union{name: "DynamicOutput", types: types} = root_union
        assert "DynamicOutputA" in types
        assert "DynamicOutputB" in types
      end

      test "root union of primitives produces named union" do
        schema = Zoi.union([Zoi.string(), Zoi.integer()])
        types = TypeBuilder.from_schema(schema)

        assert [%TB.Union{name: "DynamicOutput", types: ["string", "int"]}] = types
      end

      test "root union respects custom :name option" do
        schema = Zoi.union([Zoi.string(), Zoi.integer()])
        types = TypeBuilder.from_schema(schema, name: "PluginAction")

        assert [%TB.Union{name: "PluginAction", types: ["string", "int"]}] = types
      end

      test "root union of structs uses discriminator for variant names" do
        schema =
          Zoi.union([
            Zoi.object(%{type: Zoi.literal("get_skill"), name: Zoi.string()}),
            Zoi.object(%{type: Zoi.literal("search"), query: Zoi.string()})
          ])

        types = TypeBuilder.from_schema(schema, name: "PluginAction")

        class_names = Enum.filter(types, &match?(%TB.Class{}, &1)) |> Enum.map(& &1.name)
        assert "PluginActionGetSkill" in class_names
        assert "PluginActionSearch" in class_names

        root_union = Enum.find(types, &match?(%TB.Union{name: "PluginAction"}, &1))
        assert %TB.Union{name: "PluginAction"} = root_union
      end

      test "non-discriminated union falls back to VariantN naming" do
        schema =
          Zoi.union([
            Zoi.object(%{name: Zoi.string()}),
            Zoi.object(%{count: Zoi.integer()})
          ])

        types = TypeBuilder.from_schema(schema)
        class_names = Enum.filter(types, &match?(%TB.Class{}, &1)) |> Enum.map(& &1.name)

        assert "DynamicOutputVariant0" in class_names
        assert "DynamicOutputVariant1" in class_names
      end

      test "nested union inside object field does not produce extra named union" do
        schema =
          Zoi.object(%{
            value: Zoi.union([Zoi.string(), Zoi.integer()])
          })

        types = TypeBuilder.from_schema(schema)
        assert [%TB.Class{name: "DynamicOutput"}] = types
        refute Enum.any?(types, &match?(%TB.Union{name: _}, &1))
      end

      test "root object does not produce extra union" do
        schema = Zoi.object(%{name: Zoi.string()})
        types = TypeBuilder.from_schema(schema)

        assert [%TB.Class{name: "DynamicOutput"}] = types
        refute Enum.any?(types, &match?(%TB.Union{}, &1))
      end
    end

    describe "from_schema/2 with struct schemas" do
      defmodule TestPerson do
        defstruct [:name, :age]
      end

      test "normalizes struct schemas to objects and converts" do
        schema = Zoi.struct(TestPerson, %{name: Zoi.string(), age: Zoi.integer()})
        types = TypeBuilder.from_schema(schema)

        assert [%TB.Class{name: "DynamicOutput", fields: fields}] = types
        assert Enum.any?(fields, &(&1.name == "name" and &1.type == "string"))
        assert Enum.any?(fields, &(&1.name == "age" and &1.type == "int"))
      end
    end

    describe "from_schema/2 with literals" do
      test "converts literal values to Literal struct" do
        schema = Zoi.object(%{type: Zoi.literal("action")})

        [%TB.Class{fields: [%TB.Field{name: "type", type: type}]}] =
          TypeBuilder.from_schema(schema)

        assert %TB.Literal{value: "action"} = type
      end

      test "handles integer literals" do
        schema = Zoi.object(%{version: Zoi.literal(1)})

        [%TB.Class{fields: [%TB.Field{name: "version", type: type}]}] =
          TypeBuilder.from_schema(schema)

        assert %TB.Literal{value: 1} = type
      end
    end

    describe "from_schema/2 with custom root name" do
      test "uses provided :name option" do
        schema = Zoi.object(%{name: Zoi.string()})
        types = TypeBuilder.from_schema(schema, name: "PersonOutput")

        assert [%TB.Class{name: "PersonOutput"}] = types
      end

      test "propagates custom name to nested type names" do
        schema =
          Zoi.object(%{
            address: Zoi.object(%{city: Zoi.string()})
          })

        types = TypeBuilder.from_schema(schema, name: "Person")

        assert Enum.any?(types, &(&1.name == "PersonAddress"))
        assert Enum.any?(types, &(&1.name == "Person"))
      end
    end

    describe "from_schema/2 with descriptions" do
      test "propagates field descriptions" do
        schema =
          Zoi.object(%{
            name: Zoi.string(description: "The person's full name"),
            age: Zoi.integer(description: "Age in years")
          })

        [%TB.Class{fields: fields}] = TypeBuilder.from_schema(schema)

        name_field = Enum.find(fields, &(&1.name == "name"))
        age_field = Enum.find(fields, &(&1.name == "age"))

        assert name_field.description == "The person's full name"
        assert age_field.description == "Age in years"
      end

      test "sets nil description when not provided" do
        schema = Zoi.object(%{name: Zoi.string()})

        [%TB.Class{fields: [%TB.Field{description: description}]}] =
          TypeBuilder.from_schema(schema)

        assert is_nil(description)
      end

      test "injects descriptions into tagged union variants via descriptions option" do
        schema =
          Zoi.union([
            Zoi.object(%{type: Zoi.literal("list_skills"), query: Zoi.string()}),
            Zoi.object(%{type: Zoi.literal("search"), term: Zoi.string()})
          ])

        types =
          TypeBuilder.from_schema(schema,
            descriptions: %{"list_skills" => "Lists all available skills"}
          )

        list_class = Enum.find(types, &match?(%TB.Class{name: "DynamicOutputListSkills"}, &1))
        type_field = Enum.find(list_class.fields, &(&1.name == "type"))
        assert type_field.description == "Lists all available skills"

        search_class = Enum.find(types, &match?(%TB.Class{name: "DynamicOutputSearch"}, &1))
        search_type_field = Enum.find(search_class.fields, &(&1.name == "type"))
        assert is_nil(search_type_field.description)
      end
    end

    describe "from_schema/2 with generic objects" do
      test "converts generic object to Map type" do
        schema = Zoi.object(%{metadata: Zoi.map()})

        [%TB.Class{fields: [%TB.Field{name: "metadata", type: type}]}] =
          TypeBuilder.from_schema(schema)

        assert %TB.Map{key_type: "string", value_type: "string"} = type
      end
    end

    describe "from_schema/2 with snake_case field names" do
      test "generates PascalCase child type names from snake_case fields" do
        schema =
          Zoi.object(%{
            home_address: Zoi.object(%{zip_code: Zoi.string()})
          })

        types = TypeBuilder.from_schema(schema)

        assert Enum.any?(types, &(&1.name == "DynamicOutputHomeAddress"))
      end
    end
  end
end
