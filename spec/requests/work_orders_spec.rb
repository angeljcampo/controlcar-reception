# frozen_string_literal: true

require "rails_helper"

RSpec.describe "WorkOrders", type: :request do
  describe "GET /work_orders" do
    it "renderiza la lista correctamente" do
      get work_orders_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /work_orders/new" do
    it "renderiza el form de nueva OT" do
      get new_work_order_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Patente")
    end

    it "NO incluye un campo priority (LLM autoridad — Fase 3)" do
      get new_work_order_path
      # El form no debe tener input/select de priority
      expect(response.body).not_to match(/name="work_order\[priority\]"/i)
    end
  end

  describe "POST /work_orders" do
    let(:valid_params) {
      {
        work_order: {
          patente:       "TEST01",
          customer_name: "Cliente Test",
          mileage:       50_000,
          reason:        "Tirita en ralentí",
          make:          "Toyota",
          model:         "Corolla",
          year:          2020
        }
      }
    }

    context "happy path" do
      it "crea Vehicle + WorkOrder y redirige al show" do
        expect {
          post work_orders_path, params: valid_params
        }.to change(WorkOrder, :count).by(1)

        expect(response).to redirect_to(work_order_path(WorkOrder.last))
      end

      it "encola AnalyzeWorkOrderJob" do
        expect {
          post work_orders_path, params: valid_params
        }.to have_enqueued_job(AnalyzeWorkOrderJob)
      end

      it "deja flash[:notice] con mensaje de éxito" do
        post work_orders_path, params: valid_params
        expect(flash[:notice]).to be_present
      end
    end

    context "params inválidos" do
      it "re-renderiza el form con status 422" do
        post work_orders_path, params: { work_order: { reason: "" } }

        expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
      end

      it "no encola job ni crea registros" do
        expect {
          post work_orders_path, params: { work_order: { patente: "", reason: "" } }
        }.to change(WorkOrder, :count).by(0)

        expect(AnalyzeWorkOrderJob).not_to have_been_enqueued
      end
    end

    context "intento de pasar priority en params (no permitido)" do
      it "ignora silenciosamente el priority del request (LLM autoridad)" do
        post work_orders_path, params: valid_params.deep_merge(work_order: { priority: "low" })

        # WO se creó pero priority sigue nil (la setea el job, no el user)
        expect(WorkOrder.last.priority).to be_nil
      end
    end
  end

  describe "GET /work_orders/:id" do
    let(:wo) {
      v = Vehicle.create!(patente: "SHOW01")
      v.work_orders.create!(customer_name: "x", reason: "x", mileage: 0)
    }

    it "renderiza el show" do
      get work_order_path(wo)
      expect(response).to have_http_status(:ok)
    end

    it "muestra patente del vehículo" do
      get work_order_path(wo)
      expect(response.body).to include("SHOW01")
    end
  end

  describe "POST /work_orders/:id/reanalyze" do
    let(:wo) {
      v = Vehicle.create!(patente: "REAN01")
      v.work_orders.create!(customer_name: "x", reason: "x", mileage: 0, status: "analyzed")
    }

    it "flippea status a :analyzing + encola job" do
      expect {
        post reanalyze_work_order_path(wo)
      }.to have_enqueued_job(AnalyzeWorkOrderJob).with(wo.id)

      expect(wo.reload.status).to eq("analyzing")
    end

    it "redirige al show con notice" do
      post reanalyze_work_order_path(wo)
      expect(response).to redirect_to(work_order_path(wo))
    end

    context "WO ya cancelada" do
      before { wo.update!(status: "cancelled") }

      it "no encola job ni cambia status" do
        expect {
          post reanalyze_work_order_path(wo)
        }.not_to have_enqueued_job(AnalyzeWorkOrderJob)

        expect(wo.reload.status).to eq("cancelled")
      end
    end
  end

  describe "POST /work_orders/:id/cancel" do
    let(:wo) {
      v = Vehicle.create!(patente: "CAN01")
      v.work_orders.create!(customer_name: "x", reason: "x", mileage: 0, status: "draft")
    }

    it "cambia status a :cancelled" do
      post cancel_work_order_path(wo)
      expect(wo.reload.status).to eq("cancelled")
    end

    it "idempotente: segunda cancel no rompe" do
      post cancel_work_order_path(wo)
      expect { post cancel_work_order_path(wo) }.not_to raise_error
    end
  end
end
