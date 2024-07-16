# frozen_string_literal: true

# Author:  Paul Sadauskas<paul@sadauskas.com>
# License: MIT

#
# Better defaults for Rails migrations
#
# Example:
#
# class CreateUsers < ActiveRecord::Migration[7.2]
#   using BetterMigrationDefaults
#
module BetterMigrationDefaults
  # * Makes created_at and update_at NOT NULL with a default
  # * Adds `discarded_at` by default
  # * Handles an `:except` list of timestamps to skip
  module BetterTimestamps
    def timestamps(except: [], only: %i[created_at updated_at discarded_at], **)
      types = Array.wrap(only) - Array.wrap(except)
      opts = {null: false, default: -> { "now()" }}

      column :created_at, :datetime, **opts if types.include?(:created_at)
      column :updated_at, :datetime, **opts if types.include?(:updated_at)
      column :discarded_at, :datetime if types.include?(:discarded_at)
    end
  end

  # Rails thinks it should be generating index names, but fails miserably on
  # long ones, and postgres does fine on its own. There's no way to force Rails to let
  # postgres choose, but this implementation emulates what postgres would do.
  #
  # Fixes this error:
  # ArgumentError: Index name
  # 'index_long_table_name_on_long_column_one_and_long_column_two_and_long_column_three' on
  # table 'long_table_name' is too long; the limit is 63 characters
  module BetterIndexNaming
    def index(columns, **options)
      options[:name] ||= [@name.first(29), *columns].join("_").first(59) + "_idx"
      super
    end

    def add_index_options(table_name, column_name, comment: nil, **options)
      options[:name] ||= [table_name.first(29), *column_name].join("_").first(59) + "_idx"
      options[:algorithm] ||= :concurrently if ActiveRecord::Migration.disable_ddl_transaction
      super
    end
  end

  # Pick some better defauls for `references`. Always ensure it uses a foreign key with ON DELETE
  # CASCADE, and use a better name for the fkey. 
  module BetterReferenceNaming
    # Make all references have a foreign_key constraint, and be not null by default
    def references(*args, **options)
      options[:foreign_key] = true unless options.key?(:foreign_key)
      options[:null] = false unless options.key?(:null)
      super
    end

    # Make all references have a foreign_key constraint, and be not null by default
    def add_reference(table_name, ref_name, **options)
      options[:foreign_key] = true unless options.key?(:foreign_key)
      options[:null] = false unless options.key?(:null)
      super
    end

    # For some unfathomable reason, rails auto-generates key names like
    # "fk_rails_99326fb65d", even though postgres is capable of generating
    # better names itself. This emulates postgres's naming.
    def foreign_key_name(table_name, options)
      options.fetch(:name) do
        "#{table_name}_#{options.fetch(:column)}_fkey"
      end
    end

    # Make references ON DELETE CASCADE by default
    def foreign_key_options(from_table, to_table, options)
      super.tap do |options|
        options[:on_delete] ||= :cascade
      end
    end
  end

  # Often times in migrations you need longer statement and lock timeouts. Use this to set a timeout
  # for the duration of a block. Also changes the default timeout to migrations to 1 minute.
  module BetterTimeouts
    # Set the statement & lock timeout to a number of seconds
    #
    # Ex: set_timeout(10.minutes)
    def set_timeout(statement_timeout, lock_timeout = statement_timeout)
      statement_timeout = "#{statement_timeout.to_i}s" unless statement_timeout.is_a? String
      lock_timeout = "#{lock_timeout.to_i}s" unless lock_timeout.is_a? String
      safety_assured do
        say "Setting timeouts: statement_timeout=#{statement_timeout} lock_timeout=#{lock_timeout}"
        suppress_messages do
          execute "SET statement_timeout = '#{statement_timeout}'"
          execute "SET lock_timeout = '#{lock_timeout}'"
        end
      end
    end

    # Set the statement & lock timeout to a number of seconds for the duration of the block
    #
    # Ex: with_timeout(10.minutes) { run queries }
    def with_timeout(statement_timeout, lock_timeout = statement_timeout)
      original_statement_timeout = original_lock_timeout = nil
      suppress_messages do
        original_statement_timeout = select_value("SHOW statement_timeout")
        original_lock_timeout = select_value("SHOW lock_timeout")
      end

      set_timeout(statement_timeout, lock_timeout)
      yield
    ensure
      set_timeout(original_statement_timeout, original_lock_timeout)
    end

    # Changes the default statement and lock timeout for migrations
    def migrate(...)
      with_timeout(1.minute) { super }
    end
  end

  # When using Papertail to maintain versions of records, there are advantages to having a separate
  # table for each versioned table, instead of a giant STI table for all of them.
  module CreateVersionsTable
    def create_versions_table(name)
      singular_name = name.to_s.singularize
      create_table :"auditing_#{singular_name}_versions" do |t|
        t.references singular_name
        t.string :event, null: false
        t.string :whodunnit
        t.jsonb :object
        t.jsonb :object_changes

        t.datetime :created_at
      end
    end
  end

  module CreateEnum
    # :reek:TooManyStatements :reek:NestedIterators
    def create_enum(name, values)
      reversible do |dir|
        dir.up do
          say_with_time "create_enum(:#{name})" do
            suppress_messages do
              execute "CREATE TYPE #{name} AS ENUM (#{values.map{ |v| quote(v) }.join(', ')})"
            end
          end
        end

        dir.down do
          say_with_time "drop_enum(:#{name})" do
            execute "DROP TYPE #{name}"
          end
        end
      end
    end
  end

  module UpdateEnum
    def update_enum(table:, column:, enum_type:, old_value:, new_value:)
      new_enumlabels = new_enumlabels(enum_type, old_value, new_value)
      ActiveRecord::Base.connection.execute <<-SQL.squish
        ALTER TYPE #{enum_type} ADD VALUE IF NOT EXISTS '#{new_value}';
      SQL
      ActiveRecord::Base.connection.execute <<-SQL.squish
        ALTER TYPE #{enum_type} RENAME TO old_#{enum_type};
        CREATE TYPE #{enum_type} AS ENUM (#{new_enumlabels});
        UPDATE #{table} SET #{column} = '#{new_value}' WHERE #{table}.#{column} = '#{old_value}';
        ALTER TABLE #{table} ALTER COLUMN #{column} TYPE #{enum_type} USING #{column}::text::#{enum_type};
        DROP TYPE old_#{enum_type};
      SQL
    end

    # Fetch the enum labels from the data base
    def new_enumlabels(enum_type, old_value, new_value)
      enumlabels = ActiveRecord::Base.connection.execute <<-SQL.squish
        SELECT enumlabel from pg_enum WHERE enumtypid=(
          SELECT oid FROM pg_type WHERE typname='#{enum_type}'
        ) ORDER BY enumsortorder;
      SQL
      enumlabels = enumlabels.map { |e| "'#{e['enumlabel']}'" }
      new_labels = enumlabels.to_a - ["'#{old_value}'"] + ["'#{new_value}'"]
      new_labels.uniq.join(", ").chomp(", ")
    end
  end

  module RemoveEnumValue
    def remove_enum_value(table:, column:, enum_type:, value:)
      reversible do |dir|
        dir.up do
          say_with_time "remove_enum_value(#{value})" do
            suppress_messages do
              updated_enum_labels = update_enum_labels(enum_type, value)
              ActiveRecord::Base.connection.execute <<-SQL.squish
                DELETE FROM  #{table} WHERE #{column} = '#{value}';
                ALTER TYPE #{enum_type} RENAME TO old_#{enum_type};
                CREATE TYPE #{enum_type} AS ENUM (#{updated_enum_labels});
                ALTER TABLE #{table} ALTER COLUMN #{column} TYPE #{enum_type} USING #{column}::text::#{enum_type};
                DROP TYPE old_#{enum_type};
              SQL
            end
          end
        end

        dir.down do
          say_with_time "add_enum_value(#{value})" do
            execute "ALTER TYPE #{enum_type} ADD VALUE '#{value}'"
          end
        end
      end
    end

    # Fetch the enum labels from the data base
    def update_enum_labels(enum_type, value)
      enumlabels = ActiveRecord::Base.connection.select_values <<-SQL.squish
        SELECT enumlabel from pg_enum WHERE enumtypid=(
          SELECT oid FROM pg_type WHERE typname='#{enum_type}'
        ) ORDER BY enumsortorder;
      SQL
      enumlabels.without(value.to_s).map{ |enum| "'#{enum}'" }.join(", ")
    end
  end

  # If you blindly add a NOT NULL constraint to an existing column on a large table, it can be slow
  # while postgres checks that all the rows have a value, and it locks the table while its doing so. 
  # Instad, add a NOT VALID constraint (doesn't lock), validate the constraint (doesn't lock), then
  # add the NOT NULL (locks, but is fast becuse we already validated it). Finally, drop the old
  # constraint.
  module SafeAddNullConstraint
    def safe_add_column_null(table, column)
      constraint = "#{table}_#{column}_not_null"

      begin
        execute %{ALTER TABLE #{table} ADD CONSTRAINT #{constraint} CHECK (#{column} IS NOT NULL) NOT VALID}
      rescue ActiveRecord::StatementInvalid => ex
        # Makes this safe to re-run by ignoring duplicate constraint being added
        raise unless ex.cause.is_a?(PG::DuplicateObject)
      end

      execute %{ALTER TABLE #{table} VALIDATE CONSTRAINT #{constraint}}

      change_column_null table, column, false

      execute %{ALTER TABLE #{table} DROP CONSTRAINT #{constraint}}
    end
  end


  # Fixes `create_table`
  refine ActiveRecord::ConnectionAdapters::TableDefinition do
    import_methods BetterTimestamps
    import_methods BetterIndexNaming
    import_methods BetterReferenceNaming
  end

  # Fixes `change_table`
  refine ActiveRecord::ConnectionAdapters::Table do
    import_methods BetterTimestamps
    import_methods BetterIndexNaming
    import_methods BetterReferenceNaming
  end

  refine ActiveRecord::Migration do
    import_methods CreateVersionsTable
    import_methods SafeAddNullConstraint
  end
  # Refinement doesn't work here, no idea why
  ActiveRecord::Migration.prepend BetterTimeouts

  # Fixes `add_index`, `add_reference`
  require "active_record/connection_adapters/postgresql_adapter"
  # refine ActiveRecord::ConnectionAdapters::PostgreSQLAdapter do
  #   import_methods BetterIndexNaming
  #   import_methods BetterReferenceNaming
  # end
  # Refinement doesn't work here, no idea why
  ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend BetterIndexNaming
  ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend BetterReferenceNaming
end

