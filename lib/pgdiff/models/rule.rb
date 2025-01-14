module PgDiff
  module Models
    class Rule < Base
      def world_type
        "RULE"
      end

      def name
        gid
      end

      def to_s
        gid
      end

      def ops
        JSON.parse(@data['ops'])
      end

      def ddl
        add
      end

      def add
        ""
      end

      def remove
        ""
      end
    end
  end
end
