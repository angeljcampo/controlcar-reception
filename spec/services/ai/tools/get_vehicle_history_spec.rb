# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Tools::GetVehicleHistory do
  let(:vehicle) { Vehicle.create!(patente: "ABC123", make: "Toyota", model: "Corolla", year: 2020) }
  let(:current_wo) { vehicle.work_orders.create!(customer_name: "X", mileage: 50_000, reason: "actual", status: "draft") }
  let(:tool) { described_class.new(context: { work_order: current_wo }) }

  describe ".tool_name / .description / .input_schema" do
    it "expone metadata estándar para tool calling" do
      expect(described_class.tool_name).to eq("get_vehicle_history")
      expect(described_class.description).to include("patente")
      expect(described_class.input_schema.dig(:properties, :patente, :type)).to eq("string")
      expect(described_class.input_schema[:required]).to include("patente")
    end
  end

  describe "#call" do
    context "patente que existe en BD" do
      let!(:past_wo) {
        vehicle.work_orders.create!(customer_name: "Y", mileage: 30_000, reason: "previo", status: "analyzed")
      }

      it "devuelve found: true con metadata del vehículo" do
        result = tool.call(patente: "ABC123")

        expect(result[:found]).to be true
        expect(result[:patente]).to eq("ABC123")
        expect(result[:make]).to eq("Toyota")
      end

      it "normaliza patente (uppercase + sin espacios) antes de buscar" do
        result = tool.call(patente: "  abc 123  ")
        expect(result[:found]).to be true
      end

      it "excluye la WO actual del historial (no devuelve la del context)" do
        result = tool.call(patente: "ABC123")

        ids = result[:previous_work_orders].map { |w| w[:id] }
        expect(ids).to include(past_wo.id)
        expect(ids).not_to include(current_wo.id)
      end
    end

    context "patente que NO existe" do
      it "devuelve found: false sin raise" do
        result = tool.call(patente: "ZZZ999")

        expect(result[:found]).to be false
        expect(result[:patente]).to eq("ZZZ999")
        expect(result[:message]).to be_present
      end
    end

    context "vehículo sin WorkOrders anteriores" do
      it "previous_work_orders es array vacío (no nil)" do
        # vehicle existe pero solo tiene current_wo (que se excluye)
        result = tool.call(patente: "ABC123")
        expect(result[:previous_work_orders]).to eq([])
      end
    end
  end
end
