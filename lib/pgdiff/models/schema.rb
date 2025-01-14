module PgDiff
  module Models
    class Schema < Base
      def initialize(data)
        super(data)
      end

      def name
        nspname
      end

      def to_s
        "SCHEMA #{nspname}"
      end

      def world_type
        "SCHEMA"
      end

      def ddl
        add
      end

      def add
        return "" if nspname == "public"
        %Q{CREATE SCHEMA IF NOT EXISTS "#{nspname}";}
      end

      def remove
        return "" if nspname == "public"

        %Q{DROP SCHEMA "#{nspname}";}
      end

      def change(diff, target)
        return "" if nspname == "public"
      end
    end
  end
end