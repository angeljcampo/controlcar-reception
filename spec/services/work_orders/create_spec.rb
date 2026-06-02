# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkOrders::Create do
  let(:valid_params) {
    {
      patente:       "ABC123",
      customer_name: "Juan Pérez",
      mileage:       50_000,
      reason:        "Falla en el motor",
      make:          "Toyota",
      model:         "Corolla",
      year:          2020
    }
  }

  describe ".call" do
    context "happy path" do
      it "crea Vehicle + WorkOrder" do
        expect {
          described_class.call(valid_params)
        }.to change(Vehicle, :count).by(1)
         .and change(WorkOrder, :count).by(1)
      end

      it "asocia el WorkOrder al Vehicle" do
        result = described_class.call(valid_params)
        expect(result.work_order.vehicle.patente).to eq("ABC123")
      end

      it "encola AnalyzeWorkOrderJob (fire-and-forget AI)" do
        expect {
          described_class.call(valid_params)
        }.to have_enqueued_job(AnalyzeWorkOrderJob)
      end

      it "deja la WO en status :analyzing (spinner muestra al redirect)" do
        result = described_class.call(valid_params)
        expect(result.work_order.status).to eq("analyzing")
      end

      it "success? es true" do
        expect(described_class.call(valid_params).success?).to be true
      end
    end

    context "normalización de patente" do
      it "uppercase + sin espacios" do
        result = described_class.call(valid_params.merge(patente: "  abc 123  "))
        expect(result.work_order.vehicle.patente).to eq("ABC123")
      end
    end

    context "Vehicle existente con la misma patente" do
      let!(:existing) { Vehicle.create!(patente: "ABC123", make: "Toyota", model: "Corolla") }

      it "no duplica, reusa el vehicle" do
        expect {
          described_class.call(valid_params)
        }.not_to change(Vehicle, :count)
      end

      it "no pisa metadata con blancos del form" do
        # Re-submit sin year → no debe nullear el year previo (si tuviera)
        existing.update!(year: 2018)
        described_class.call(valid_params.merge(year: nil, make: nil))

        expect(existing.reload.year).to eq(2018) # preservado
      end
    end

    context "patente vacía" do
      it "no crea Vehicle ni WorkOrder" do
        expect {
          described_class.call(valid_params.merge(patente: "   "))
        }.not_to change(Vehicle, :count)
      end

      it "agrega error en patente" do
        result = described_class.call(valid_params.merge(patente: ""))

        expect(result.success?).to be_falsey
        expect(result.work_order.errors[:patente]).to be_present
      end

      it "no encola job de análisis" do
        expect {
          described_class.call(valid_params.merge(patente: ""))
        }.not_to have_enqueued_job(AnalyzeWorkOrderJob)
      end
    end

    context "params inválidos (reason vacío)" do
      it "success? es false y no encola job" do
        expect {
          result = described_class.call(valid_params.merge(reason: ""))
          expect(result.success?).to be false
        }.not_to have_enqueued_job(AnalyzeWorkOrderJob)
      end
    end
  end
end
