require "test_helper"

# This app shares a Postgres database with other applications, so every table it
# owns must live in its own schema.
#
# These assertions exist because the failure they catch is silent. Postgres skips
# a missing entry in `search_path` rather than erroring, so a broken
# configuration does not raise — it quietly creates tables in `public`, where
# another application's `schema_migrations` already is. Nothing in the logs would
# say so, and the first symptom would be two apps sharing one migration ledger.
class DatabaseNamespaceTest < ActiveSupport::TestCase
  SCHEMA = "pdfrag".freeze

  # Every table this application owns, including the ones Rails and Active
  # Storage create on its behalf. The Rails-internal two are the reason a schema
  # was chosen over a table prefix: a prefix reaches only what someone remembers
  # to prefix.
  OWNED_TABLES = %w[
    documents document_chunks messages
    active_storage_blobs active_storage_attachments active_storage_variant_records
    schema_migrations ar_internal_metadata
  ].freeze

  setup do
    @connection = ActiveRecord::Base.connection
  end

  test "the configured search path names the app schema first and public second" do
    configured = ActiveRecord::Base.connection_db_config.configuration_hash[:schema_search_path]

    assert_equal "#{SCHEMA},public", configured,
      "database.yml must put #{SCHEMA} ahead of public"
  end

  # `public` is load-bearing rather than habitual: the vector extension may live
  # there, and a search path without it leaves every embedding column unable to
  # resolve its type.
  test "the live connection resolves the app schema before public" do
    path = @connection.select_value("SHOW search_path").to_s.split(",").map(&:strip)

    assert_equal SCHEMA, path.first, "expected #{SCHEMA} first in #{path.inspect}"
    assert_includes path, "public", "public must stay on the path for the vector extension"
  end

  test "the app schema exists" do
    assert @connection.schema_exists?(SCHEMA),
      "schema #{SCHEMA} is missing; search_path would silently fall through to public"
  end

  test "every table this app owns lives in the app schema" do
    OWNED_TABLES.each do |table|
      assert_equal SCHEMA, schema_of(table),
        "#{table} is not in the #{SCHEMA} schema"
    end
  end

  test "no table this app owns is left in public" do
    stranded = OWNED_TABLES.select { |table| table_in?(table, "public") }

    assert_empty stranded,
      "these belong to this app but are in public, shared with every other app on this database: #{stranded.join(', ')}"
  end

  test "the schema name is read from the search path rather than hardcoded twice" do
    assert_equal SCHEMA, DatabaseSchemaNamespace.configured_name
  end

  test "verification refuses to continue when the schema is absent" do
    error = assert_raises(RuntimeError) do
      DatabaseSchemaNamespace.verify!(@connection, "schema_that_does_not_exist")
    end

    assert_match(/refusing to continue/i, error.message)
  end

  private
    def schema_of(table)
      @connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          [ "SELECT schemaname FROM pg_tables WHERE tablename = ? LIMIT 1", table ]
        )
      )
    end

    def table_in?(table, schema)
      @connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          [ "SELECT 1 FROM pg_tables WHERE tablename = ? AND schemaname = ?", table, schema ]
        )
      ).present?
    end
end
