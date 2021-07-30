module PgDiff
  module Models
    class Extension < Base
      def name
        "#{schema}.#{@data['name']}"
      end

      def to_s
        "EXTENSION #{name}"
      end

      def world_type
        "EXTENSION"
      end

      def add
        %Q{CREATE EXTENSION IF NOT EXISTS "#{@data['name']}" WITH SCHEMA #{schema};}
      end

      def drop
        %Q{DROP EXTENSION "#{@data['name']}";}
      end
    end
  end
end

# [{"schema"=>"app", "name"=>"api_key_status", "elements"=>"{enabled,disabled,blacklisted}"}]