require "pg"
require "dagwood"

module PgDiff; end

require_relative "pgdiff/utils.rb"
require_relative "pgdiff/world.rb"
require_relative "pgdiff/queries.rb"
require_relative "pgdiff/models/base.rb"
require_relative "pgdiff/models/role.rb"
require_relative "pgdiff/models/rule.rb"
require_relative "pgdiff/models/type.rb"
require_relative "pgdiff/models/unmapped.rb"
require_relative "pgdiff/models/extension.rb"
require_relative "pgdiff/models/aggregate.rb"
require_relative "pgdiff/models/function_privilege.rb"
require_relative "pgdiff/models/function.rb"
require_relative "pgdiff/models/table_column.rb"
require_relative "pgdiff/models/table_constraint.rb"
require_relative "pgdiff/models/table_index.rb"
require_relative "pgdiff/models/table_option.rb"
require_relative "pgdiff/models/table_privilege.rb"
require_relative "pgdiff/models/table.rb"
require_relative "pgdiff/models/schema.rb"
require_relative "pgdiff/models/view_privilege.rb"
require_relative "pgdiff/models/view.rb"
require_relative "pgdiff/models/enum.rb"
require_relative "pgdiff/models/sequence_privilege.rb"
require_relative "pgdiff/models/sequence.rb"
require_relative "pgdiff/models/domain_constraint.rb"
require_relative "pgdiff/models/domain.rb"
require_relative "pgdiff/models/custom_type.rb"
require_relative "pgdiff/models/trigger.rb"
require_relative "pgdiff/catalog.rb"
require_relative "pgdiff/object.rb"
require_relative "pgdiff/dependency.rb"
require_relative "pgdiff/dependencies.rb"
require_relative "pgdiff/database.rb"
require_relative "pgdiff/diff.rb"
require_relative "pgdiff/cli/options.rb"
require_relative "pgdiff/cli/parser.rb"
require_relative "pgdiff/cli.rb"
require_relative "pgdiff/destructurer.rb"

def PgDiff.args=(args)
  @args = args
end

def PgDiff.args
  @args || PgDiff::Cli::Options.default
end

def PgDiff.compare(source, target)
  diff = PgDiff::Diff.new(source, target)
  diff.to_sql
end