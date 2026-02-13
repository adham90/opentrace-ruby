# frozen_string_literal: true

RSpec.describe "Exception cause chaining" do
  before do
    OpenTrace.reset!
    OpenTrace.configure do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-app"
      c.flush_interval = 0.2
    end
    stub_request(:any, /opentrace\.test/).to_return(status: 200, body: "{}")
  end

  after { OpenTrace.shutdown(timeout: 1) }

  describe "OpenTrace.error with cause chain" do
    it "captures a single cause" do
      begin
        begin
          raise StandardError, "root cause"
        rescue
          raise RuntimeError, "wrapper error"
        end
      rescue => e
        # The wrapper has one cause (root)
        chain = OpenTrace.send(:build_cause_chain, e.cause, depth: 0)
        expect(chain).to be_an(Array)
        expect(chain.length).to eq(1)
        expect(chain[0][:class]).to eq("StandardError")
        expect(chain[0][:message]).to eq("root cause")
      end
    end

    it "captures a chain of causes" do
      begin
        begin
          begin
            raise ArgumentError, "level 3"
          rescue
            raise TypeError, "level 2"
          end
        rescue
          raise RuntimeError, "level 1"
        end
      rescue => e
        chain = OpenTrace.send(:build_cause_chain, e.cause, depth: 0)
        expect(chain).to be_an(Array)
        expect(chain.length).to eq(2)
        expect(chain[0][:class]).to eq("TypeError")
        expect(chain[0][:message]).to eq("level 2")
        expect(chain[1][:class]).to eq("ArgumentError")
        expect(chain[1][:message]).to eq("level 3")
      end
    end

    it "limits cause chain depth to 5" do
      # Build a chain of 7 exceptions
      exceptions = []
      7.times do |i|
        begin
          if exceptions.empty?
            raise StandardError, "exception #{i}"
          else
            begin
              raise exceptions.last
            rescue
              raise StandardError, "exception #{i}"
            end
          end
        rescue => e
          exceptions << e
        end
      end

      last = exceptions.last
      chain = OpenTrace.send(:build_cause_chain, last.cause, depth: 0)
      # Should be capped at 5
      expect(chain.length).to be <= 5
    end

    it "returns nil for no cause" do
      chain = OpenTrace.send(:build_cause_chain, nil, depth: 0)
      expect(chain).to be_nil
    end

    it "includes backtrace origin in cause entries" do
      begin
        begin
          raise ArgumentError, "root"
        rescue
          raise RuntimeError, "wrapper"
        end
      rescue => e
        chain = OpenTrace.send(:build_cause_chain, e.cause, depth: 0)
        expect(chain[0][:class]).to eq("ArgumentError")
        expect(chain[0][:backtrace]).to be_an(Array)
        expect(chain[0][:backtrace].length).to be <= 5
        expect(chain[0][:origin]).to be_a(String)
      end
    end

    it "truncates cause messages to 300 chars" do
      long_message = "x" * 500
      begin
        begin
          raise StandardError, long_message
        rescue
          raise RuntimeError, "wrapper"
        end
      rescue => e
        chain = OpenTrace.send(:build_cause_chain, e.cause, depth: 0)
        expect(chain[0][:message].length).to be <= 300
      end
    end

    it "attaches causes to error payloads" do
      begin
        begin
          raise ArgumentError, "root cause"
        rescue
          raise RuntimeError, "wrapper"
        end
      rescue => e
        # Intercept the log call to check metadata
        allow(OpenTrace).to receive(:log) do |level, msg, meta|
          expect(level).to eq("ERROR")
          expect(meta[:exception_causes]).to be_an(Array)
          expect(meta[:exception_causes][0][:class]).to eq("ArgumentError")
        end
        OpenTrace.error(e)
      end
    end

    it "does not include causes when there are none" do
      e = RuntimeError.new("no cause")
      allow(OpenTrace).to receive(:log) do |level, msg, meta|
        expect(meta).not_to have_key(:exception_causes)
      end
      OpenTrace.error(e)
    end
  end

  describe "clean_backtrace_for" do
    it "filters gem lines when Rails is not defined" do
      e = RuntimeError.new("test")
      e.set_backtrace([
        "app/models/user.rb:42:in `authenticate'",
        "/gems/bcrypt/lib/bcrypt.rb:10:in `hash'",
        "app/controllers/sessions_controller.rb:15:in `create'"
      ])
      cleaned = OpenTrace.send(:clean_backtrace_for, e)
      expect(cleaned).to eq([
        "app/models/user.rb:42:in `authenticate'",
        "app/controllers/sessions_controller.rb:15:in `create'"
      ])
    end
  end
end
