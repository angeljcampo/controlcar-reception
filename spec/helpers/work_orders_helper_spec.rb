# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkOrdersHelper, type: :helper do
  let(:vehicle) { Vehicle.create!(patente: "X") }
  let(:wo) { vehicle.work_orders.create!(customer_name: "x", reason: "x", mileage: 0) }

  describe "#priority_badge" do
    context "con priority asignada" do
      before { wo.update!(priority: "high") }

      it "renderiza un pill con la priority_label" do
        out = helper.priority_badge(wo)
        expect(out).to be_present
        expect(out).to include("inline-flex")
      end
    end

    context "con priority nil (LLM no terminó — Fase 3)" do
      it "devuelve nil (la UI no renderiza pill)" do
        wo.update!(priority: nil)
        expect(helper.priority_badge(wo)).to be_nil
      end
    end
  end

  describe "#priority_with_suffix_badge" do
    it "devuelve nil cuando priority es nil" do
      wo.update!(priority: nil)
      expect(helper.priority_with_suffix_badge(wo)).to be_nil
    end

    it "incluye el sufijo 'Prioridad' cuando hay priority" do
      wo.update!(priority: "high")
      expect(helper.priority_with_suffix_badge(wo)).to be_present
    end
  end

  describe "#status_badge" do
    it "siempre renderiza algo (status no es nullable)" do
      wo.update!(status: "analyzed")
      expect(helper.status_badge(wo)).to be_present
    end
  end
end
