# frozen_string_literal: true

module OpenTrace
  # Auto-included concern on ActiveRecord::Base when audit_tracking is enabled.
  # Captures before/after diffs on create, update, and destroy using saved_changes.
  module AuditTracker
    def self.included(base)
      base.after_create  { |record| OpenTrace::AuditTracker.track(record, :create) }
      base.after_update  { |record| OpenTrace::AuditTracker.track(record, :update) }
      base.after_destroy { |record| OpenTrace::AuditTracker.track(record, :destroy) }
    end

    class << self
      def track(record, action)
        buffer = Fiber[:opentrace_buffer]
        return unless buffer
        return unless OpenTrace.config.audit_tracking

        model_name = record.class.name
        return if excluded_model?(model_name)

        # Resolve actor
        actor_id = nil
        actor_type = nil
        actor_proc = OpenTrace.config.audit_actor
        if actor_proc.is_a?(Proc)
          actor = actor_proc.call rescue nil
          if actor
            actor_id = actor.respond_to?(:id) ? actor.id.to_s : actor.to_s
            actor_type = actor.class.name
          end
        end

        case action
        when :create
          after_values = filter_fields(record.attributes)
          buffer.record_audit(
            action: "create",
            record_type: model_name,
            record_id: record.id.to_s,
            actor_id: actor_id,
            actor_type: actor_type,
            changed_fields: nil,
            full_before: nil,
            full_after: after_values
          )

        when :update
          changes = record.saved_changes
          return if changes.empty?

          filtered = filter_changes(changes)
          return if filtered.empty?

          changed_fields = {}
          filtered.each do |field, (old_val, new_val)|
            changed_fields[field] = { "from" => old_val, "to" => new_val }
          end

          buffer.record_audit(
            action: "update",
            record_type: model_name,
            record_id: record.id.to_s,
            actor_id: actor_id,
            actor_type: actor_type,
            changed_fields: changed_fields,
            full_before: nil,
            full_after: nil
          )

        when :destroy
          before_values = filter_fields(record.attributes)
          buffer.record_audit(
            action: "destroy",
            record_type: model_name,
            record_id: record.id.to_s,
            actor_id: actor_id,
            actor_type: actor_type,
            changed_fields: nil,
            full_before: before_values,
            full_after: nil
          )
        end

        buffer.record_timeline(type: :audit, name: "#{model_name}##{action}")
      rescue StandardError
        # Never affect the host app
      end

      private

      def excluded_model?(model_name)
        OpenTrace.config.audit_exclude_models.any? { |m| model_name == m }
      rescue StandardError
        false
      end

      def filter_changes(changes)
        exclude = OpenTrace.config.audit_exclude_fields
        changes.reject { |field, _| exclude.include?(field.to_s) }
      rescue StandardError
        changes
      end

      def filter_fields(attributes)
        exclude = OpenTrace.config.audit_exclude_fields
        attributes.reject { |field, _| exclude.include?(field.to_s) }
      rescue StandardError
        attributes
      end
    end
  end
end
