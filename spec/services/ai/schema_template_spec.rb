# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::SchemaTemplate do
  describe ".load" do
    context "con un schema válido" do
      it "devuelve un Hash con symbol keys" do
        schema = described_class.load("respond_with_analysis")

        expect(schema).to be_a(Hash)
        expect(schema.keys).to all(be_a(Symbol))
        expect(schema[:type]).to eq("object")
      end

      it "strippea recursivamente las keys con prefix _ (meta-info para humanos)" do
        schema = described_class.load("respond_with_analysis")

        # Top-level _meta no debe estar
        expect(schema).not_to have_key(:_meta)

        # Tampoco en nested objects
        deep_walk(schema) do |hash|
          hash.keys.each do |k|
            expect(k.to_s).not_to start_with("_"),
              "Encontré key con prefix _ después de strip: #{k.inspect}"
          end
        end
      end

      it "preserva enums críticos del schema (priority, category, probability)" do
        schema = described_class.load("respond_with_analysis")

        expect(schema.dig(:properties, :priority, :enum))
          .to eq(%w[low medium high critical])
        expect(schema.dig(:properties, :category, :enum))
          .to include("engine", "brakes", "fuel", "transmission")
        expect(schema.dig(:properties, :possible_failures, :items, :properties, :probability, :enum))
          .to eq(%w[high medium low])
      end
    end

    context "cuando el schema no existe" do
      it "raises NotFound con un mensaje útil" do
        expect {
          described_class.load("schema_inexistente")
        }.to raise_error(described_class::NotFound, /schema_inexistente/)
      end
    end

    context "cuando el JSON es inválido" do
      let(:bad_schema) { Rails.root.join("config/schemas/__test_bad.json") }

      before { File.write(bad_schema, "{ not valid json") }
      after  { File.delete(bad_schema) if File.exist?(bad_schema) }

      it "raises InvalidJson con info de la línea/columna del error" do
        expect {
          described_class.load("__test_bad")
        }.to raise_error(described_class::InvalidJson, /__test_bad/)
      end
    end
  end

  # Walks a nested hash/array structure, yielding each Hash encountered.
  # Usado para verificar invariantes a través del tree (ej: que no quede
  # ninguna key con prefix _).
  def deep_walk(value, &block)
    case value
    when Hash
      yield value
      value.each_value { |v| deep_walk(v, &block) }
    when Array
      value.each { |v| deep_walk(v, &block) }
    end
  end
end
