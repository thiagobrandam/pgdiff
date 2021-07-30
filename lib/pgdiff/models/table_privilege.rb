module PgDiff
  module Models
    class TablePrivilege < Base
      attr_reader :table

      def initialize(data, table)
        super(data)
        @table = table
      end

      def name
        "#{schemaname}.#{tablename}"
      end

      def user
        usename
      end

      def id
        "TABLE PRIVILEGE #{user} #{operations.join(", ")}"
      end

      def operations
        [
          "select",
          "insert",
          "update",
          "delete",
          "truncate",
          "references",
          "trigger"
        ].map do |op|
          @data[op] == "t" ? "CAN #{op.upcase} ON #{name}" : "CANNOT #{op.upcase} ON #{name}"
        end
      end
    end
  end
end


# {"schemaname"=>"app",
#   "tablename"=>"user_accounts",
#   "usename"=>"admin",
#   "select"=>"f",
#   "insert"=>"f",
#   "update"=>"f",
#   "delete"=>"f",
#   "truncate"=>"f",
#   "references"=>"f",
#   "trigger"=>"f"},