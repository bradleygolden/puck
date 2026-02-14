if Code.ensure_loaded?(BamlElixir.Client) do
  defmodule Puck.Backends.Baml.TypeBuilder do
    @moduledoc """
    Converts Zoi schemas to `BamlElixir.TypeBuilder` structs.

    When using the BAML backend with `output_schema`, Zoi schemas define the
    expected output structure but BAML's Rust runtime has no knowledge of these
    types. This module bridges the gap by converting Zoi schemas into
    `BamlElixir.TypeBuilder` structs that can be passed as the `:tb` option,
    giving BAML full knowledge of the schema for Schema-Aligned Parsing and
    prompt formatting via `ctx.output_format`.

    ## Pipeline

    1. Normalize struct schemas to object schemas (structs can't be JSON encoded)
    2. Convert to JSON Schema via `Zoi.to_json_schema/1`
    3. Recursively convert JSON Schema nodes to TypeBuilder structs

    ## Examples

        iex> schema = Zoi.object(%{name: Zoi.string(), age: Zoi.integer()})
        iex> types = Puck.Backends.Baml.TypeBuilder.from_schema(schema)
        iex> [%BamlElixir.TypeBuilder.Class{name: "DynamicOutput"}] = types

    """

    alias BamlElixir.TypeBuilder, as: TB

    @doc """
    Builds TypeBuilder structs for a union schema with dynamic classes.

    When a union schema has runtime-declared dynamic classes, this function
    emits a `TB.Enum` for the type discriminator (with per-value descriptions)
    and a `TB.Class` for the shared dynamic fields. Non-type fields are collected
    from all dynamic schemas and emitted as `string | null` unions.

    Returns a flat list of `TB.Enum` and `TB.Class` structs.
    """
    def from_dynamic_union(
          %Zoi.Types.Union{schemas: schemas},
          dynamic_classes,
          schema_descriptions \\ %{}
        ) do
      dynamic_modules =
        dynamic_classes
        |> Map.values()
        |> List.flatten()
        |> MapSet.new()

      dynamic_schemas =
        Enum.filter(schemas, fn
          %Zoi.Types.Struct{module: mod} -> mod in dynamic_modules
          _ -> false
        end)

      type_values =
        Enum.flat_map(dynamic_schemas, fn %Zoi.Types.Struct{fields: fields} ->
          case Keyword.get(fields, :type) do
            %Zoi.Types.Enum{values: [{value, _} | _]} -> [value]
            %Zoi.Types.Enum{values: [value | _]} when is_binary(value) -> [value]
            _ -> []
          end
        end)

      dynamic_fields =
        dynamic_schemas
        |> Enum.flat_map(fn %Zoi.Types.Struct{fields: fields} ->
          fields
          |> Keyword.keys()
          |> Enum.reject(&(&1 == :type))
          |> Enum.map(&to_string/1)
        end)
        |> Enum.uniq()

      Enum.flat_map(dynamic_classes, fn {class_name, _modules} ->
        type_enum_name = class_name <> "Type"

        type_enum = %TB.Enum{
          name: type_enum_name,
          values:
            Enum.map(type_values, fn value ->
              %TB.EnumValue{
                value: value,
                description: Map.get(schema_descriptions, value)
              }
            end)
        }

        other_fields =
          Enum.map(dynamic_fields, fn name ->
            %TB.Field{name: name, type: %TB.Union{types: [:string, :null]}, description: ""}
          end)

        class = %TB.Class{
          name: class_name,
          fields: other_fields
        }

        [type_enum, class]
      end)
    end

    @doc """
    Converts a Zoi schema to a list of `BamlElixir.TypeBuilder` structs.

    Returns a list of named types (classes, enums) that BAML's Rust runtime
    needs to know about. Inline types (lists, maps, unions, literals) are
    embedded directly in field type references.

    ## Options

      * `:name` - Root type name (default: `"DynamicOutput"`)

    """
    def from_schema(zoi_schema, opts \\ []) do
      name = Keyword.get(opts, :name, "DynamicOutput")
      descriptions = Keyword.get(opts, :descriptions, %{})

      json_schema =
        zoi_schema
        |> normalize_schema()
        |> Zoi.to_json_schema()
        |> Map.delete(:"$schema")
        |> inject_descriptions(descriptions)

      {ref, state} = convert(json_schema, name, %{types: []})
      state = maybe_add_root_union(ref, name, state)
      Enum.reverse(state.types)
    end

    defp normalize_schema(%Zoi.Types.Struct{fields: fields}),
      do: Zoi.object(fields, unrecognized_keys: :error)

    defp normalize_schema(%Zoi.Types.Union{schemas: schemas} = union),
      do: %{union | schemas: Enum.map(schemas, &normalize_schema/1)}

    defp normalize_schema(schema), do: schema

    # --- Convert dispatch ---

    # String enum — must precede plain string match
    defp convert(%{type: :string, enum: values}, name, state) do
      enum_type = %TB.Enum{
        name: name,
        values: Enum.map(values, fn v -> %TB.EnumValue{value: to_string(v)} end)
      }

      {name, add_type(state, enum_type)}
    end

    # Object with properties
    defp convert(%{type: :object, properties: props} = schema, name, state)
         when is_map(props) do
      required = Map.get(schema, :required, [])
      schema_description = Map.get(schema, :description)

      {fields, state} =
        props
        |> Enum.sort_by(fn {k, _} -> to_string(k) end)
        |> Enum.reduce({[], state}, fn {field_name, field_schema}, {fields_acc, state_acc} ->
          field_name_str = to_string(field_name)
          child_name = name <> pascal_case(field_name_str)
          description = Map.get(field_schema, :description)

          description =
            if is_nil(description) and schema_description != nil and
                 discriminator_field?(field_name, field_schema) do
              schema_description
            else
              description
            end

          {type_ref, state_acc} = convert(field_schema, child_name, state_acc)

          type_ref =
            if field_name not in required and not nullable_schema?(field_schema) do
              make_nullable(type_ref)
            else
              type_ref
            end

          field = %TB.Field{
            name: field_name_str,
            type: type_ref,
            description: description
          }

          {[field | fields_acc], state_acc}
        end)

      class = %TB.Class{name: name, fields: Enum.reverse(fields)}
      {name, add_type(state, class)}
    end

    # Generic object (no properties)
    defp convert(%{type: :object}, _name, state) do
      {%TB.Map{key_type: "string", value_type: "string"}, state}
    end

    # Array with items
    defp convert(%{type: :array, items: items}, name, state) do
      {inner_ref, state} = convert(items, name, state)
      {%TB.List{type: inner_ref}, state}
    end

    # Array without items
    defp convert(%{type: :array}, _name, state) do
      {%TB.List{type: "string"}, state}
    end

    # Primitives
    defp convert(%{type: :string}, _name, state), do: {"string", state}
    defp convert(%{type: :integer}, _name, state), do: {"int", state}
    defp convert(%{type: :number}, _name, state), do: {"float", state}
    defp convert(%{type: :boolean}, _name, state), do: {"bool", state}
    defp convert(%{type: :null}, _name, state), do: {"null", state}

    # Literal
    defp convert(%{const: value}, _name, state) do
      {%TB.Literal{value: value}, state}
    end

    # anyOf — nullable or general union
    defp convert(%{anyOf: variants}, name, state) do
      case extract_nullable(variants) do
        {:nullable, inner} ->
          {inner_ref, state} = convert(inner, name, state)
          {make_nullable(inner_ref), state}

        :not_nullable ->
          {type_refs, state} =
            variants
            |> Enum.with_index()
            |> Enum.reduce({[], state}, fn {variant, idx}, {refs_acc, state_acc} ->
              variant_name = infer_variant_name(variant, name, idx)
              {ref, state_acc} = convert(variant, variant_name, state_acc)
              {[ref | refs_acc], state_acc}
            end)

          {%TB.Union{types: Enum.reverse(type_refs)}, state}
      end
    end

    # --- Helpers ---

    defp extract_nullable(variants) do
      non_null = Enum.reject(variants, &match?(%{type: :null}, &1))

      if length(non_null) == length(variants) - 1 and length(non_null) == 1 do
        {:nullable, hd(non_null)}
      else
        :not_nullable
      end
    end

    defp nullable_schema?(%{anyOf: variants}),
      do: Enum.any?(variants, &match?(%{type: :null}, &1))

    defp nullable_schema?(_), do: false

    defp make_nullable(ref) when is_binary(ref), do: ref <> "?"
    defp make_nullable(ref), do: %TB.Union{types: [ref, "null"]}

    defp maybe_add_root_union(%TB.Union{} = union, name, state),
      do: add_type(state, %{union | name: name})

    defp maybe_add_root_union(_ref, _name, state), do: state

    defp add_type(state, type), do: %{state | types: [type | state.types]}

    defp discriminator_field?(field_name, %{enum: [_]}),
      do: field_name in [:type, "type"]

    defp discriminator_field?(field_name, %{const: _}),
      do: field_name in [:type, "type"]

    defp discriminator_field?(_, _), do: false

    defp inject_descriptions(%{anyOf: variants} = schema, descriptions)
         when map_size(descriptions) > 0 do
      updated =
        Enum.map(variants, fn variant ->
          case extract_discriminator(Map.get(variant, :properties, %{})) do
            nil -> variant
            disc -> Map.put(variant, :description, Map.get(descriptions, disc, nil))
          end
        end)

      %{schema | anyOf: updated}
    end

    defp inject_descriptions(schema, _descriptions), do: schema

    defp infer_variant_name(%{type: :object, properties: props}, name, idx) do
      case extract_discriminator(props) do
        nil -> "#{name}Variant#{idx}"
        disc_value -> name <> pascal_case(disc_value)
      end
    end

    defp infer_variant_name(_variant, name, idx), do: "#{name}Variant#{idx}"

    defp extract_discriminator(props) when is_map(props) do
      case Map.get(props, :type) || Map.get(props, "type") do
        %{enum: [value]} when is_binary(value) -> value
        %{const: value} when is_binary(value) -> value
        _ -> nil
      end
    end

    defp extract_discriminator(_), do: nil

    defp pascal_case(str) do
      str
      |> String.split("_")
      |> Enum.map_join(&String.capitalize/1)
    end
  end
end
