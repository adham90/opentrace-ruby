# frozen_string_literal: true

require "spec_helper"
require "active_support/callbacks"
require "opentrace/audit_tracker"
require "opentrace/request_buffer"

# Mock AR record for testing — mimics the ActiveRecord interface used by AuditTracker
class MockRecord
  attr_accessor :id

  def initialize(id:, attributes: {}, saved_changes: {})
    @id = id
    @attributes = attributes
    @saved_changes = saved_changes
  end

  def attributes
    @attributes
  end

  def saved_changes
    @saved_changes
  end
end

# A mock actor object for testing audit_actor resolution
class MockActor
  attr_reader :id

  def initialize(id)
    @id = id
  end
end

RSpec.describe OpenTrace::AuditTracker do
  let(:buffer) { OpenTrace::RequestBuffer.new }

  before do
    OpenTrace.reset!
    OpenTrace.configure do |c|
      c.endpoint = "http://opentrace.test"
      c.api_key = "test-key"
      c.service = "test"
      c.audit_tracking = true
      c.audit_exclude_fields = %w[updated_at created_at password_digest]
    end

    Fiber[:opentrace_buffer] = buffer
    buffer.id = "test-buffer-id"
    buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    buffer.event_type = :http_request
  end

  after do
    Fiber[:opentrace_buffer] = nil
    OpenTrace.reset!
  end

  describe ".track with :create" do
    it "records audit with full_after attributes" do
      record = MockRecord.new(
        id: 42,
        attributes: { "id" => 42, "name" => "Alice", "email" => "alice@example.com" }
      )

      described_class.track(record, :create)

      expect(buffer.audit_captures.size).to eq(1)
      audit = buffer.audit_captures.first
      expect(audit[:action]).to eq("create")
      expect(audit[:record_type]).to eq("MockRecord")
      expect(audit[:record_id]).to eq("42")
      expect(audit[:full_after]).to eq({ "id" => 42, "name" => "Alice", "email" => "alice@example.com" })
      expect(audit[:full_before]).to be_nil
      expect(audit[:changed_fields]).to be_nil
    end

    it "filters excluded fields from full_after on create" do
      record = MockRecord.new(
        id: 1,
        attributes: { "id" => 1, "name" => "Bob", "updated_at" => "2026-01-01", "created_at" => "2026-01-01", "password_digest" => "hash123" }
      )

      described_class.track(record, :create)

      audit = buffer.audit_captures.first
      expect(audit[:full_after]).to eq({ "id" => 1, "name" => "Bob" })
      expect(audit[:full_after]).not_to have_key("updated_at")
      expect(audit[:full_after]).not_to have_key("created_at")
      expect(audit[:full_after]).not_to have_key("password_digest")
    end
  end

  describe ".track with :update" do
    it "records changed_fields with from/to" do
      record = MockRecord.new(
        id: 42,
        saved_changes: { "name" => ["Alice", "Alicia"], "email" => ["old@ex.com", "new@ex.com"] }
      )

      described_class.track(record, :update)

      expect(buffer.audit_captures.size).to eq(1)
      audit = buffer.audit_captures.first
      expect(audit[:action]).to eq("update")
      expect(audit[:record_type]).to eq("MockRecord")
      expect(audit[:record_id]).to eq("42")
      expect(audit[:changed_fields]).to eq({
        "name" => { "from" => "Alice", "to" => "Alicia" },
        "email" => { "from" => "old@ex.com", "to" => "new@ex.com" }
      })
      expect(audit[:full_before]).to be_nil
      expect(audit[:full_after]).to be_nil
    end

    it "skips excluded fields (updated_at, created_at, password_digest)" do
      record = MockRecord.new(
        id: 42,
        saved_changes: {
          "name" => ["Alice", "Alicia"],
          "updated_at" => ["2026-01-01", "2026-01-02"],
          "created_at" => ["2026-01-01", "2026-01-02"],
          "password_digest" => ["oldhash", "newhash"]
        }
      )

      described_class.track(record, :update)

      audit = buffer.audit_captures.first
      expect(audit[:changed_fields].keys).to eq(["name"])
    end

    it "skips recording when no changes remain after filtering" do
      record = MockRecord.new(
        id: 42,
        saved_changes: {
          "updated_at" => ["2026-01-01", "2026-01-02"]
        }
      )

      described_class.track(record, :update)

      expect(buffer.audit_captures).to be_empty
    end

    it "skips recording when saved_changes is empty" do
      record = MockRecord.new(id: 42, saved_changes: {})

      described_class.track(record, :update)

      expect(buffer.audit_captures).to be_empty
    end
  end

  describe ".track with :destroy" do
    it "records audit with full_before attributes" do
      record = MockRecord.new(
        id: 42,
        attributes: { "id" => 42, "name" => "Alice", "email" => "alice@example.com" }
      )

      described_class.track(record, :destroy)

      expect(buffer.audit_captures.size).to eq(1)
      audit = buffer.audit_captures.first
      expect(audit[:action]).to eq("destroy")
      expect(audit[:record_type]).to eq("MockRecord")
      expect(audit[:record_id]).to eq("42")
      expect(audit[:full_before]).to eq({ "id" => 42, "name" => "Alice", "email" => "alice@example.com" })
      expect(audit[:full_after]).to be_nil
      expect(audit[:changed_fields]).to be_nil
    end

    it "filters excluded fields from full_before on destroy" do
      record = MockRecord.new(
        id: 1,
        attributes: { "id" => 1, "name" => "Bob", "password_digest" => "hash123" }
      )

      described_class.track(record, :destroy)

      audit = buffer.audit_captures.first
      expect(audit[:full_before]).to eq({ "id" => 1, "name" => "Bob" })
      expect(audit[:full_before]).not_to have_key("password_digest")
    end
  end

  describe "excluded models" do
    it "skips tracking for models in audit_exclude_models" do
      OpenTrace.configure do |c|
        c.endpoint = "http://opentrace.test"
        c.api_key = "test-key"
        c.service = "test"
        c.audit_tracking = true
        c.audit_exclude_models = ["MockRecord"]
      end

      record = MockRecord.new(
        id: 1,
        attributes: { "id" => 1, "name" => "test" }
      )

      described_class.track(record, :create)

      expect(buffer.audit_captures).to be_empty
    end
  end

  describe "actor resolution" do
    it "resolves actor from config.audit_actor proc" do
      actor = MockActor.new(99)
      OpenTrace.configure do |c|
        c.endpoint = "http://opentrace.test"
        c.api_key = "test-key"
        c.service = "test"
        c.audit_tracking = true
        c.audit_actor = -> { actor }
      end

      record = MockRecord.new(
        id: 42,
        attributes: { "id" => 42, "name" => "Alice" }
      )

      described_class.track(record, :create)

      audit = buffer.audit_captures.first
      expect(audit[:actor_id]).to eq("99")
      expect(audit[:actor_type]).to eq("MockActor")
    end

    it "handles actor_proc returning a simple string" do
      OpenTrace.configure do |c|
        c.endpoint = "http://opentrace.test"
        c.api_key = "test-key"
        c.service = "test"
        c.audit_tracking = true
        c.audit_actor = -> { "system" }
      end

      record = MockRecord.new(id: 1, attributes: { "id" => 1 })
      described_class.track(record, :create)

      audit = buffer.audit_captures.first
      expect(audit[:actor_id]).to eq("system")
      expect(audit[:actor_type]).to eq("String")
    end

    it "handles actor_proc that raises an error" do
      OpenTrace.configure do |c|
        c.endpoint = "http://opentrace.test"
        c.api_key = "test-key"
        c.service = "test"
        c.audit_tracking = true
        c.audit_actor = -> { raise "boom" }
      end

      record = MockRecord.new(id: 1, attributes: { "id" => 1 })
      described_class.track(record, :create)

      audit = buffer.audit_captures.first
      expect(audit[:actor_id]).to be_nil
      expect(audit[:actor_type]).to be_nil
    end

    it "leaves actor nil when audit_actor is not configured" do
      record = MockRecord.new(id: 1, attributes: { "id" => 1 })
      described_class.track(record, :create)

      audit = buffer.audit_captures.first
      expect(audit[:actor_id]).to be_nil
      expect(audit[:actor_type]).to be_nil
    end
  end

  describe "timeline recording" do
    it "records a timeline entry for tracked actions" do
      record = MockRecord.new(
        id: 42,
        attributes: { "id" => 42, "name" => "Alice" }
      )

      described_class.track(record, :create)

      expect(buffer.timeline.size).to eq(1)
      entry = buffer.timeline.first
      expect(entry[:type]).to eq(:audit)
      expect(entry[:name]).to eq("MockRecord#create")
    end

    it "records timeline for update actions" do
      record = MockRecord.new(
        id: 42,
        saved_changes: { "name" => ["Alice", "Alicia"] }
      )

      described_class.track(record, :update)

      entry = buffer.timeline.first
      expect(entry[:name]).to eq("MockRecord#update")
    end

    it "records timeline for destroy actions" do
      record = MockRecord.new(
        id: 42,
        attributes: { "id" => 42 }
      )

      described_class.track(record, :destroy)

      entry = buffer.timeline.first
      expect(entry[:name]).to eq("MockRecord#destroy")
    end
  end

  describe "audit_max_events_per_request" do
    it "respects the max events limit via buffer.record_audit" do
      small_buffer = OpenTrace::RequestBuffer.new(max_audit_events: 3)
      small_buffer.id = "test-id"
      small_buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      small_buffer.event_type = :http_request
      Fiber[:opentrace_buffer] = small_buffer

      5.times do |i|
        record = MockRecord.new(
          id: i + 1,
          attributes: { "id" => i + 1, "name" => "Record #{i + 1}" }
        )
        described_class.track(record, :create)
      end

      expect(small_buffer.audit_captures.size).to eq(3)
      expect(small_buffer.audit_truncated?).to be true
    end
  end

  describe "callback integration" do
    def build_callback_model_class
      Class.new do
        include ActiveSupport::Callbacks

        define_callbacks :create, :update, :destroy

        class << self
          attr_accessor :job_dispatches

          def after_create(&block)
            set_callback(:create, :after, &block)
          end

          def after_update(&block)
            set_callback(:update, :after, &block)
          end

          def after_destroy(&block)
            set_callback(:destroy, :after, &block)
          end
        end

        attr_reader :id, :attributes, :saved_changes

        def initialize
          @id = 123
          @attributes = { "id" => 123, "title" => "hello" }
          @saved_changes = { "title" => ["old", "hello"] }
        end

        def create!
          run_callbacks(:create) {}
        end

        def update!
          run_callbacks(:update) {}
        end

        def destroy!
          run_callbacks(:destroy) {}
        end
      end
    end

    it "does not duplicate host after_create callbacks when audit tracking is included" do
      model_class = build_callback_model_class
      model_class.job_dispatches = 0
      model_class.after_create do |_record|
        model_class.job_dispatches += 1
      end
      model_class.include(described_class)

      model_class.new.create!

      expect(model_class.job_dispatches).to eq(1)
      expect(buffer.audit_captures.size).to eq(1)
      expect(buffer.audit_captures.first[:action]).to eq("create")
    end

    it "does not duplicate audit callbacks if the module is included twice" do
      model_class = build_callback_model_class
      model_class.include(described_class)
      model_class.include(described_class)

      model_class.new.create!

      expect(buffer.audit_captures.size).to eq(1)
      expect(buffer.audit_captures.first[:action]).to eq("create")
    end

    it "registers one audit callback per lifecycle event" do
      model_class = build_callback_model_class
      model_class.include(described_class)
      record = model_class.new

      record.create!
      record.update!
      record.destroy!

      expect(buffer.audit_captures.map { |audit| audit[:action] }).to eq(%w[create update destroy])
    end

    it "does not record or dispatch anything when audit_tracking is disabled" do
      OpenTrace.config.audit_tracking = false
      model_class = build_callback_model_class
      model_class.job_dispatches = 0
      model_class.after_create do |_record|
        model_class.job_dispatches += 1
      end
      model_class.include(described_class)

      model_class.new.create!

      expect(model_class.job_dispatches).to eq(1)
      expect(buffer.audit_captures).to be_empty
    end
  end

  describe "error safety" do
    it "swallows errors without affecting host app" do
      # Make the buffer raise on record_audit
      allow(buffer).to receive(:record_audit).and_raise(RuntimeError, "unexpected error")

      record = MockRecord.new(
        id: 42,
        attributes: { "id" => 42, "name" => "Alice" }
      )

      # Should not raise
      expect { described_class.track(record, :create) }.not_to raise_error
    end

    it "swallows errors from saved_changes" do
      record = MockRecord.new(id: 42)
      allow(record).to receive(:saved_changes).and_raise(RuntimeError, "AR error")

      expect { described_class.track(record, :update) }.not_to raise_error
    end
  end

  describe "guard clauses" do
    it "does nothing when buffer is nil" do
      Fiber[:opentrace_buffer] = nil

      record = MockRecord.new(id: 1, attributes: { "id" => 1 })

      expect { described_class.track(record, :create) }.not_to raise_error
      # No buffer means nothing was recorded — no way to check but at least no error
    end

    it "does nothing when audit_tracking is false" do
      OpenTrace.configure do |c|
        c.endpoint = "http://opentrace.test"
        c.api_key = "test-key"
        c.service = "test"
        c.audit_tracking = false
      end

      record = MockRecord.new(id: 1, attributes: { "id" => 1 })
      described_class.track(record, :create)

      expect(buffer.audit_captures).to be_empty
    end
  end
end
