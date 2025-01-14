module PgDiff
  module Models
    class TablePrivilege < Base
      OPERATIONS = [
        "select",
        "insert",
        "update",
        "delete",
        "truncate",
        "references",
        "trigger"
      ].freeze

      attr_reader :table

      def self.new(data)
        instance = allocate
        table_id = data["objid"].split(".")[0]
        if table_id && (table = PgDiff::World[data["origin"]].objects[table_id])
          instance.send(:initialize, data, table)
          instance
        else
          nil
        end
      end

      def initialize(data, table)
        @table = table
        super(data)

        table.add_privilege(self)

        world.add_dependency(
          PgDiff::Dependency.new(
            self,
            @table,
            "oncreate"
          )
        )
      end

      def name
        "#{schemaname}.#{tablename}"
      end

      def privileges
        JSON.parse(@data['privileges']).reduce({}) do |acc, h|
          acc.merge(h.keys[0] => h.values[0])
        end
      end

      def users
        privileges.keys
      end

      def world_type
        "TABLE PRIVILEGE"
      end

      def world_id
        to_s
      end

      def gid
        "TABLE PRIVILEGE ON #{table.name}"
      end

      def to_s
        %Q{
          TABLE PRIVILEGE ON #{table.name} #{
            users.sort.map do |user|
              privileges[user].sort_by {|k,v| k}.map do |k,v|
                v ? "#{user} CAN #{k}" : "#{user} CANNOT #{k}"
              end.join("\n")
            end.join("\n")
          }
        }
      end

      def ddl
        add
      end

      def add
        sql = []
        privileges.sort_by{|user, _| user }.each do |user, user_privileges|
          next if PgDiff.args.ignore_roles.include?(user)

          sql << %Q{REVOKE ALL PRIVILEGES ON #{name} FROM "#{user}";}

          user_privileges.each_pair do |operation, can|
            if can
              sql << %Q{GRANT #{operation} ON #{name} TO "#{user}";}
            end
          end

          sql << "\n"
        end

        sql.join("\n")
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