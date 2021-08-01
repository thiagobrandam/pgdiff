module PgDiff
  module Models
    class Schema < Base
      def name
        nspname
      end

      def to_s
        "SCHEMA #{nspname}"
      end

      def world_type
        "SCHEMA"
      end

      def add(diff)
        %Q{CREATE SCHEMA IF NOT EXISTS "#{nspname}";}
      end

      def remove(diff)
        %Q{DROP SCHEMA "#{nspname}";}
      end
    end
  end
end