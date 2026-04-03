# frozen_string_literal: true

require "stringio"
require "securerandom"

# Load Rails stubs
require_relative "rails_spec_helper"

RSpec.describe "Deep capture subscribers" do
  let(:buffer) { OpenTrace::RequestBuffer.new }

  before do
    configure_opentrace!(min_level: :debug)
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!

    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }

    # Set up Fiber-locals as middleware would
    buffer.id = "test-buf-001"
    buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Fiber[:opentrace_buffer] = buffer
    Fiber[:opentrace_sql_count] = 0
    Fiber[:opentrace_sql_total_ms] = 0.0
  end

  after do
    Fiber[:opentrace_buffer] = nil
    Fiber[:opentrace_sql_count] = nil
    Fiber[:opentrace_sql_total_ms] = nil
  end

  # ── SQL subscriber deep capture ──

  describe "SQL subscriber" do
    it "records SQL queries to the buffer" do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "User Load",
        sql: 'SELECT "users".* FROM "users" WHERE "users"."id" = $1',
        cached: false,
        row_count: 1
      }) {}

      expect(buffer.sql_captures.size).to eq(1)
      capture = buffer.sql_captures.first
      expect(capture[:raw_sql]).to include("SELECT")
      expect(capture[:name]).to eq("User Load")
      expect(capture[:cached]).to eq(false)
      expect(capture[:row_count]).to eq(1)
      expect(capture[:duration_ms]).to be_a(Numeric)
      expect(capture[:duration_ms]).to be >= 0
    end

    it "records bind values from type_casted_binds" do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "User Load",
        sql: 'SELECT "users".* FROM "users" WHERE "users"."id" = $1',
        cached: false,
        type_casted_binds: [42, "hello"]
      }) {}

      capture = buffer.sql_captures.first
      expect(capture[:binds]).to eq([42, "hello"])
    end

    it "records bind values from binds when type_casted_binds is absent" do
      bind_obj = Struct.new(:value).new("some_value")
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "User Load",
        sql: 'SELECT "users".* FROM "users" WHERE "users"."name" = $1',
        cached: false,
        binds: [bind_obj]
      }) {}

      capture = buffer.sql_captures.first
      expect(capture[:binds]).to eq(["some_value"])
    end

    it "detects in_transaction flag" do
      # ActiveRecord::Base is not defined in test stubs, so in_transaction defaults to false
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "User Load",
        sql: 'SELECT * FROM users WHERE id = 1',
        cached: false
      }) {}

      capture = buffer.sql_captures.first
      expect(capture[:in_transaction]).to eq(false)
    end

    it "records SQL to timeline" do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "User Load",
        sql: 'SELECT * FROM users WHERE id = 1',
        cached: false
      }) {}

      expect(buffer.timeline.size).to eq(1)
      entry = buffer.timeline.first
      expect(entry[:type]).to eq(:sql)
      expect(entry[:name]).to eq("User Load")
      expect(entry[:duration_ms]).to be_a(Numeric)
      expect(entry[:offset_ms]).to be_a(Numeric)
    end

    it "extracts table name from SQL" do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "Order Load",
        sql: 'SELECT * FROM orders WHERE id = 1',
        cached: false
      }) {}

      capture = buffer.sql_captures.first
      expect(capture[:table]).to eq("orders")
    end

    it "extracts table name from INSERT" do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "Order Create",
        sql: "INSERT INTO orders (user_id) VALUES ($1)",
        cached: false
      }) {}

      capture = buffer.sql_captures.first
      expect(capture[:table]).to eq("orders")
    end

    it "generates a fingerprint" do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "User Load",
        sql: 'SELECT * FROM users WHERE id = 1',
        cached: false
      }) {}

      capture = buffer.sql_captures.first
      expect(capture[:fingerprint]).to be_a(String)
      expect(capture[:fingerprint].length).to eq(8)
    end

    it "skips SCHEMA queries" do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "SCHEMA",
        sql: "SELECT version FROM schema_migrations"
      }) {}

      expect(buffer.sql_captures).to be_empty
      expect(buffer.timeline).to be_empty
    end

    it "skips PRAGMA queries" do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: nil,
        sql: "PRAGMA table_info('users')"
      }) {}

      expect(buffer.sql_captures).to be_empty
    end
  end

  # ── ActionMailer subscriber ──

  describe "ActionMailer subscriber" do
    it "records email metadata to buffer" do
      # Build a minimal mail-like struct
      mail_body = Struct.new(:decoded).new("Hello plain text")
      mail = Struct.new(:from, :to, :subject, :html_part, :text_part, :body, :attachments)
                   .new(["sender@example.com"], ["recipient@example.com"], "Test Subject",
                        nil, mail_body, mail_body, [])

      ActiveSupport::Notifications.instrument("deliver.action_mailer", {
        mailer: "UserMailer",
        action: "welcome",
        mail: mail,
        perform_deliveries: true
      }) {}

      expect(buffer.email_captures.size).to eq(1)
      capture = buffer.email_captures.first
      expect(capture[:mailer_class]).to eq("UserMailer")
      expect(capture[:mailer_action]).to eq("welcome")
      expect(capture[:from]).to eq("sender@example.com")
      expect(capture[:to]).to eq(["recipient@example.com"])
      expect(capture[:subject]).to eq("Test Subject")
      expect(capture[:body_text]).to eq("Hello plain text")
      expect(capture[:delivery_status]).to eq("delivered")
      expect(capture[:duration_ms]).to be_a(Numeric)
    end

    it "records email to timeline" do
      mail_body = Struct.new(:decoded).new("text")
      mail = Struct.new(:from, :to, :subject, :html_part, :text_part, :body, :attachments)
                   .new(["a@b.com"], ["c@d.com"], "Hi", nil, mail_body, mail_body, [])

      ActiveSupport::Notifications.instrument("deliver.action_mailer", {
        mailer: "OrderMailer",
        action: "confirm",
        mail: mail,
        perform_deliveries: true
      }) {}

      expect(buffer.timeline.size).to eq(1)
      entry = buffer.timeline.first
      expect(entry[:type]).to eq(:email)
      expect(entry[:name]).to eq("OrderMailer#confirm")
    end

    it "marks delivery_status as skipped when perform_deliveries is false" do
      mail_body = Struct.new(:decoded).new("text")
      mail = Struct.new(:from, :to, :subject, :html_part, :text_part, :body, :attachments)
                   .new(["a@b.com"], ["c@d.com"], "Hi", nil, mail_body, mail_body, [])

      ActiveSupport::Notifications.instrument("deliver.action_mailer", {
        mailer: "UserMailer",
        action: "welcome",
        mail: mail,
        perform_deliveries: false
      }) {}

      capture = buffer.email_captures.first
      expect(capture[:delivery_status]).to eq("skipped")
    end

    it "does not record when buffer is nil" do
      Fiber[:opentrace_buffer] = nil

      mail_body = Struct.new(:decoded).new("text")
      mail = Struct.new(:from, :to, :subject, :html_part, :text_part, :body, :attachments)
                   .new(["a@b.com"], ["c@d.com"], "Hi", nil, mail_body, mail_body, [])

      ActiveSupport::Notifications.instrument("deliver.action_mailer", {
        mailer: "UserMailer",
        action: "welcome",
        mail: mail,
        perform_deliveries: true
      }) {}

      # Buffer was nil, so nothing should have been captured
      expect(buffer.email_captures).to be_empty
    end

    it "records attachments metadata" do
      attachment_body = Struct.new(:raw_source).new("x" * 1024)
      attachment = Struct.new(:filename, :body, :content_type)
                        .new("report.pdf", attachment_body, "application/pdf")

      mail_body = Struct.new(:decoded).new("See attached")
      mail = Struct.new(:from, :to, :subject, :html_part, :text_part, :body, :attachments)
                   .new(["a@b.com"], ["c@d.com"], "Report", nil, mail_body, mail_body, [attachment])

      ActiveSupport::Notifications.instrument("deliver.action_mailer", {
        mailer: "ReportMailer",
        action: "send_report",
        mail: mail,
        perform_deliveries: true
      }) {}

      capture = buffer.email_captures.first
      expect(capture[:attachments]).to be_an(Array)
      expect(capture[:attachments].size).to eq(1)
      expect(capture[:attachments].first[:name]).to eq("report.pdf")
      expect(capture[:attachments].first[:size]).to eq(1024)
      expect(capture[:attachments].first[:content_type]).to eq("application/pdf")
    end
  end

  # ── ActiveStorage subscriber ──

  describe "ActiveStorage subscriber" do
    before do
      # Define the ActiveStorage module so the `defined?(ActiveStorage)` guard passes.
      # Must be defined before Railtie runs, so re-initialize subscribers.
      stub_const("ActiveStorage", Module.new) unless defined?(ActiveStorage)
      ActiveSupport::Notifications.reset!

      app = Rails::Application.new
      app.config.logger = ::Logger.new(StringIO.new)
      OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
      OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
    end

    it "records upload events to buffer" do
      ActiveSupport::Notifications.instrument("service_upload.active_storage", {
        key: "abc123/photo.jpg",
        bytesize: 204_800,
        content_type: "image/jpeg",
        service: "Disk"
      }) {}

      expect(buffer.file_captures.size).to eq(1)
      capture = buffer.file_captures.first
      expect(capture[:action]).to eq("upload")
      expect(capture[:filename]).to eq("abc123/photo.jpg")
      expect(capture[:size_bytes]).to eq(204_800)
      expect(capture[:content_type]).to eq("image/jpeg")
      expect(capture[:service]).to eq("Disk")
      expect(capture[:key]).to eq("abc123/photo.jpg")
      expect(capture[:duration_ms]).to be_a(Numeric)
    end

    it "records download events to buffer" do
      ActiveSupport::Notifications.instrument("service_download.active_storage", {
        key: "abc123/report.pdf",
        content_length: 51_200,
        content_type: "application/pdf",
        service: "S3"
      }) {}

      capture = buffer.file_captures.first
      expect(capture[:action]).to eq("download")
      expect(capture[:size_bytes]).to eq(51_200)
    end

    it "records delete events to buffer" do
      ActiveSupport::Notifications.instrument("service_delete.active_storage", {
        key: "abc123/old_file.txt",
        service: "Disk"
      }) {}

      capture = buffer.file_captures.first
      expect(capture[:action]).to eq("delete")
      expect(capture[:filename]).to eq("abc123/old_file.txt")
    end

    it "records file operations to timeline" do
      ActiveSupport::Notifications.instrument("service_upload.active_storage", {
        key: "xyz/image.png",
        bytesize: 100,
        service: "Disk"
      }) {}

      expect(buffer.timeline.size).to eq(1)
      entry = buffer.timeline.first
      expect(entry[:type]).to eq(:file)
      expect(entry[:name]).to eq("upload xyz/image.png")
    end

    it "does not record when buffer is nil" do
      Fiber[:opentrace_buffer] = nil

      ActiveSupport::Notifications.instrument("service_upload.active_storage", {
        key: "abc/file.txt",
        bytesize: 100,
        service: "Disk"
      }) {}

      expect(buffer.file_captures).to be_empty
    end
  end

  # ── View subscriber deep capture ──

  describe "View subscriber" do
    before do
      # Re-initialize with view_tracking enabled
      configure_opentrace!(view_tracking: true, min_level: :debug)
      ActiveSupport::Notifications.reset!

      app = Rails::Application.new
      app.config.logger = ::Logger.new(StringIO.new)
      OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
      OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }

      # View subscriber requires a collector for the existing code path
      Fiber[:opentrace_collector] = OpenTrace::RequestCollector.new(max_timeline: 0)
    end

    after do
      Fiber[:opentrace_collector] = nil
    end

    it "records view renders to timeline" do
      ActiveSupport::Notifications.instrument("render_template.action_view", {
        identifier: "/app/views/users/index.html.erb"
      }) {}

      expect(buffer.timeline.size).to eq(1)
      entry = buffer.timeline.first
      expect(entry[:type]).to eq(:view)
      expect(entry[:name]).to eq("users/index.html.erb")
      expect(entry[:duration_ms]).to be_a(Numeric)
    end

    it "records partial renders to timeline" do
      ActiveSupport::Notifications.instrument("render_partial.action_view", {
        identifier: "/app/views/shared/_header.html.erb"
      }) {}

      expect(buffer.timeline.size).to eq(1)
      entry = buffer.timeline.first
      expect(entry[:type]).to eq(:view)
      expect(entry[:name]).to eq("shared/_header.html.erb")
    end
  end

  # ── Cache subscriber deep capture ──

  describe "Cache subscriber" do
    before do
      configure_opentrace!(cache_tracking: true, min_level: :debug)
      ActiveSupport::Notifications.reset!

      app = Rails::Application.new
      app.config.logger = ::Logger.new(StringIO.new)
      OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
      OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }

      Fiber[:opentrace_collector] = OpenTrace::RequestCollector.new(max_timeline: 0)
    end

    after do
      Fiber[:opentrace_collector] = nil
    end

    it "records cache reads to timeline" do
      ActiveSupport::Notifications.instrument("cache_read.active_support", {
        hit: true
      }) {}

      expect(buffer.timeline.size).to eq(1)
      entry = buffer.timeline.first
      expect(entry[:type]).to eq(:cache)
      expect(entry[:name]).to eq("cache_read")
      expect(entry[:duration_ms]).to be_a(Numeric)
    end

    it "records cache writes to timeline" do
      ActiveSupport::Notifications.instrument("cache_write.active_support", {
        hit: false
      }) {}

      entry = buffer.timeline.first
      expect(entry[:name]).to eq("cache_write")
    end

    it "records cache deletes to timeline" do
      ActiveSupport::Notifications.instrument("cache_delete.active_support", {}) {}

      entry = buffer.timeline.first
      expect(entry[:name]).to eq("cache_delete")
    end
  end

  # ── Error resilience ──

  describe "error resilience" do
    it "SQL subscriber swallows errors without affecting the request" do
      # Instrument with a nil sql and malformed payload
      expect {
        ActiveSupport::Notifications.instrument("sql.active_record", {
          name: nil, sql: nil, cached: nil
        }) {}
      }.not_to raise_error
    end

    it "ActionMailer subscriber swallows errors from malformed mail object" do
      expect {
        ActiveSupport::Notifications.instrument("deliver.action_mailer", {
          mailer: "BrokenMailer",
          action: "send",
          mail: nil,           # nil mail object — will cause NoMethodError on &.from
          perform_deliveries: true
        }) {}
      }.not_to raise_error
    end

    it "SQL subscriber handles binds with objects that raise on value" do
      bad_bind = Object.new
      def bad_bind.respond_to?(m, *); m == :value ? true : super; end
      def bad_bind.value; raise "Boom!"; end

      expect {
        ActiveSupport::Notifications.instrument("sql.active_record", {
          name: "User Load",
          sql: "SELECT * FROM users WHERE id = 1",
          cached: false,
          binds: [bad_bind]
        }) {}
      }.not_to raise_error

      # The query itself should still be recorded (binds may be nil due to rescue)
      expect(buffer.sql_captures.size).to eq(1)
    end
  end

  # ── Bulk operation detection ──

  describe "bulk operation detection" do
    before do
      OpenTrace.config.audit_tracking = true
    end

    it "detects UPDATE bulk operations" do
      ActiveSupport::Notifications.instrument("sql.active_record",
        name: "SQL", sql: "UPDATE users SET active = 0 WHERE last_login < '2025-01-01'") do
        # noop
      end
      sleep 0.01
      audits = buffer.instance_variable_get(:@audit_captures)
      bulk = audits.find { |a| a[:action] == "bulk_update" }
      expect(bulk).not_to be_nil
      expect(bulk[:record_type]).to eq("users")
      expect(bulk[:actor_type]).to eq("SQL")
    end

    it "detects DELETE bulk operations" do
      ActiveSupport::Notifications.instrument("sql.active_record",
        name: "SQL", sql: "DELETE FROM sessions WHERE expired_at < '2025-01-01'") do
        # noop
      end
      sleep 0.01
      audits = buffer.instance_variable_get(:@audit_captures)
      bulk = audits.find { |a| a[:action] == "bulk_delete" }
      expect(bulk).not_to be_nil
      expect(bulk[:record_type]).to eq("sessions")
    end

    it "does not flag regular single-row INSERTs" do
      ActiveSupport::Notifications.instrument("sql.active_record",
        name: "SQL", sql: "INSERT INTO users VALUES (1, 'test')") do
        # noop
      end
      sleep 0.01
      audits = buffer.instance_variable_get(:@audit_captures)
      expect(audits.select { |a| a[:action]&.start_with?("bulk_") }).to be_empty
    end

    it "does nothing when audit_tracking is false" do
      OpenTrace.config.audit_tracking = false
      ActiveSupport::Notifications.instrument("sql.active_record",
        name: "SQL", sql: "UPDATE users SET active = 0 WHERE id > 100") do
        # noop
      end
      sleep 0.01
      audits = buffer.instance_variable_get(:@audit_captures)
      expect(audits.select { |a| a[:action]&.start_with?("bulk_") }).to be_empty
    end
  end
end
