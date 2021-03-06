# frozen_string_literal: true

module Dynamoid #:nodoc:
  # All fields on a Dynamoid::Document must be explicitly defined -- if you have fields in the database that are not
  # specified with field, then they will be ignored.
  module Fields
    extend ActiveSupport::Concern

    # Types allowed in indexes:
    PERMITTED_KEY_TYPES = %i[
      number
      integer
      string
      datetime
      serialized
    ].freeze

    # Initialize the attributes we know the class has, in addition to our magic attributes: id, created_at, and updated_at.
    included do
      class_attribute :attributes, instance_accessor: false
      class_attribute :range_key

      self.attributes = {}

      # Timestamp fields could be disabled later in `table` method call.
      # So let's declare them here and remove them later if it will be necessary
      field :created_at, :datetime if Dynamoid::Config.timestamps
      field :updated_at, :datetime if Dynamoid::Config.timestamps

      field :id # Default primary key
    end

    module ClassMethods
      # Specify a field for a document.
      #
      # Its type determines how it is coerced when read in and out of the datastore.
      # You can specify :integer, :number, :set, :array, :datetime, :date and :serialized,
      # or specify a class that defines a serialization strategy.
      #
      # If you specify a class for field type, Dynamoid will serialize using
      # `dynamoid_dump` or `dump` methods, and load using `dynamoid_load` or `load` methods.
      #
      # Default field type is :string.
      #
      # @param [Symbol] name the name of the field
      # @param [Symbol] type the type of the field (refer to method description for details)
      # @param [Hash] options any additional options for the field
      #
      # @since 0.2.0
      def field(name, type = :string, options = {})
        named = name.to_s
        if type == :float
          Dynamoid.logger.warn("Field type :float, which you declared for '#{name}', is deprecated in favor of :number.")
          type = :number
        end
        self.attributes = attributes.merge(name => { type: type }.merge(options))

        # should be called before `define_attribute_methods` method because it defines a getter itself
        warn_about_method_overriding(name, name)
        warn_about_method_overriding("#{named}=", name)
        warn_about_method_overriding("#{named}?", name)
        warn_about_method_overriding("#{named}_before_type_cast?", name)

        define_attribute_method(name) # Dirty API

        generated_methods.module_eval do
          define_method(named) { read_attribute(named) }
          define_method("#{named}?") do
            value = read_attribute(named)
            case value
            when true        then true
            when false, nil  then false
            else
              !value.nil?
            end
          end
          define_method("#{named}=") { |value| write_attribute(named, value) }
          define_method("#{named}_before_type_cast") { read_attribute_before_type_cast(named) }
        end
      end

      def range(name, type = :string, options = {})
        field(name, type, options)
        self.range_key = name
      end

      def table(options)
        # a default 'id' column is created when Dynamoid::Document is included
        unless attributes.key? hash_key
          remove_field :id
          field(hash_key)
        end

        if options[:timestamps] && !Dynamoid::Config.timestamps
          # Timestamp fields weren't declared in `included` hook because they
          # are disabled globaly
          field :created_at, :datetime
          field :updated_at, :datetime
        elsif options[:timestamps] == false && Dynamoid::Config.timestamps
          # Timestamp fields were declared in `included` hook but they are
          # disabled for a table
          remove_field :created_at
          remove_field :updated_at
        end
      end

      def remove_field(field)
        field = field.to_sym
        attributes.delete(field) || raise('No such field')

        # Dirty API
        undefine_attribute_methods
        define_attribute_methods attributes.keys

        generated_methods.module_eval do
          remove_method field
          remove_method :"#{field}="
          remove_method :"#{field}?"
          remove_method :"#{field}_before_type_cast"
        end
      end

      def timestamps_enabled?
        options[:timestamps] || (options[:timestamps].nil? && Dynamoid::Config.timestamps)
      end

      private

      def generated_methods
        @generated_methods ||= begin
          Module.new.tap do |mod|
            include(mod)
          end
        end
      end

      def warn_about_method_overriding(method_name, field_name)
        if self.instance_methods.include?(method_name.to_sym)
          Dynamoid.logger.warn("Method #{method_name} generated for the field #{field_name} overrides already existing method")
        end
      end
    end

    # You can access the attributes of an object directly on its attributes method, which is by default an empty hash.
    attr_accessor :attributes
    alias raw_attributes attributes

    # Write an attribute on the object. Also marks the previous value as dirty.
    #
    # @param [Symbol] name the name of the field
    # @param [Object] value the value to assign to that field
    #
    # @since 0.2.0
    def write_attribute(name, value)
      name = name.to_sym

      if association = @associations[name]
        association.reset
      end

      attribute_will_change!(name) # Dirty API

      @attributes_before_type_cast[name] = value

      value_casted = TypeCasting.cast_field(value, self.class.attributes[name])
      attributes[name] = value_casted
    end
    alias []= write_attribute

    # Read an attribute from an object.
    #
    # @param [Symbol] name the name of the field
    #
    # @since 0.2.0
    def read_attribute(name)
      attributes[name.to_sym]
    end
    alias [] read_attribute

    # Returns a hash of attributes before typecasting
    def attributes_before_type_cast
      @attributes_before_type_cast
    end

    # Returns the value of the attribute identified by name before typecasting
    #
    # @param [Symbol] attribute name
    def read_attribute_before_type_cast(name)
      return nil unless name.respond_to?(:to_sym)

      @attributes_before_type_cast[name.to_sym]
    end

    private

    # Automatically called during the created callback to set the created_at time.
    #
    # @since 0.2.0
    def set_created_at
      self.created_at ||= DateTime.now.in_time_zone(Time.zone) if self.class.timestamps_enabled?
    end

    # Automatically called during the save callback to set the updated_at time.
    #
    # @since 0.2.0
    def set_updated_at
      # @_touch_record=false means explicit disabling
      if self.class.timestamps_enabled? && !updated_at_changed? && @_touch_record != false
        self.updated_at = DateTime.now.in_time_zone(Time.zone)
      end
    end

    def set_expires_field
      options = self.class.options[:expires]

      if options.present?
        name = options[:field]
        seconds = options[:after]

        if self[name].blank?
          send("#{name}=", Time.now.to_i + seconds)
        end
      end
    end

    def set_inheritance_field
      # actually it does only following logic:
      # self.type ||= self.class.name if self.class.attributes[:type]

      type = self.class.inheritance_field
      if self.class.attributes[type] && send(type).nil?
        send("#{type}=", self.class.name)
      end
    end
  end
end
