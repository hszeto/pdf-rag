# The Postgres schema this application's tables live in.
#
# This app shares one database with other applications, so it keeps everything it
# owns in its own schema rather than in `public` — its three tables, Active
# Storage's three, and Rails' `schema_migrations` and `ar_internal_metadata`. The
# last two are why a schema was chosen over a table prefix: a prefix reaches only
# the tables someone remembers to prefix, and those two are easy to forget and
# the worst to share.
#
# The reason any of this is enforced rather than documented is that the failure
# is silent. Postgres skips an entry in `search_path` that does not exist and
# falls through to the next one, so a missing schema does not raise — it puts the
# tables in `public`, next to the other application's. Measured:
#
#   SET search_path TO pdfrag,public; CREATE TABLE documents (id int);
#     => public.documents
module DatabaseSchemaNamespace
  # The schema is whatever `config/database.yml` names first, read rather than
  # repeated so that changing the search path cannot leave this creating the
  # wrong schema.
  def self.configured_name
    search_path = ActiveRecord::Base.connection_db_config.configuration_hash[:schema_search_path]
    search_path.to_s.split(",").map(&:strip).reject(&:empty?).first
  end

  # Returns what it did, so the rake task can say something useful.
  #
  # The one subtlety is knowing when *not* to act. Rails loads `db/schema.rb`
  # into an empty database rather than running migrations against it, and that
  # file begins with `create_schema` — which has no IF NOT EXISTS. Creating the
  # schema here first would make that load die on PG::DuplicateSchema, so an
  # empty database is left alone and the schema file does the work.
  def self.ensure!
    schema = configured_name
    # No dedicated schema configured, or the app lives in `public` after all.
    return :not_applicable if schema.nil? || schema == "public"

    connection = ActiveRecord::Base.connection
    return :present if connection.schema_exists?(schema)
    return :deferred unless migrated?(connection)

    # Reached only when a migration ledger exists but the schema does not, which
    # means the ledger is sitting in `public` — the state this whole arrangement
    # exists to prevent. Create the schema so migrations stop adding to it.
    connection.create_schema(schema)
    verify!(connection, schema)
    :created
  rescue ActiveRecord::NoDatabaseError
    # `db:prepare` reaches here before the database exists. It goes on to create
    # the database and load `db/schema.rb`, which creates the schema.
    :no_database
  end

  # Whether this database has been migrated before. An unmigrated one is about to
  # receive `db/schema.rb`; a migrated one will have migrations run against it.
  def self.migrated?(connection)
    connection.table_exists?("schema_migrations")
  end

  # Belt and braces. `create_schema` should make this unreachable, but the cost
  # of being wrong is tables landing silently in a database shared with other
  # applications, so it is worth one more query to be sure.
  def self.verify!(connection, schema)
    return if connection.schema_exists?(schema)

    raise <<~MESSAGE
      Schema #{schema.inspect} does not exist after attempting to create it.

      Refusing to continue: search_path falls back to `public` when a schema is
      missing, so migrating now would create this application's tables in the
      schema shared with every other app on this database.
    MESSAGE
  end
end
