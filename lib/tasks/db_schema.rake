# Creates the schema this app's tables live in, before anything tries to write
# them. See DatabaseSchemaNamespace for why this is enforced rather than left as
# a step in a README.
namespace :db do
  desc "Create the Postgres schema named first in database.yml's schema_search_path"
  task ensure_schema: :environment do
    schema = DatabaseSchemaNamespace.configured_name

    case DatabaseSchemaNamespace.ensure!
    when :created
      warn "[db] created schema #{schema.inspect} — a migration ledger existed without it, " \
           "which means earlier tables may be in `public`. Check before migrating further."
    when :deferred     then puts "[db] schema #{schema.inspect} will be created by db/schema.rb"
    when :no_database  then puts "[db] database does not exist yet; schema arrives with db/schema.rb"
    when :not_applicable then puts "[db] no dedicated schema configured; using the default search path"
    end
  end
end

# Hooked onto both routes to a migrated database. Each defers to db/schema.rb
# when that file is the one doing the work.
[ "db:migrate", "db:prepare" ].each do |name|
  Rake::Task[name].enhance([ "db:ensure_schema" ]) if Rake::Task.task_defined?(name)
end
