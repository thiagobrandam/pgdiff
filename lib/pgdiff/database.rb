module PgDiff
  class Database
    attr_reader :catalog, :world, :queries

    def initialize(label, dbparams = {})
      @label = label
      @retries = 0

      loop do
        if @retries > 10
          print "Giving up!"
          puts "There's something wrong with your database"
          exit(1)
        end
        begin
          @pg = PG.connect(dbparams)
          if @retries > 0
            print "Done"
          end
          break
        rescue PG::ConnectionBad
          print "Waiting for database '#{@label}' to be up... "
          sleep(1)
          @retries += 1
        end
      end

      setup
    end

    def connection; @pg; end

    def build_object(objdata, objclass)
      case objclass.name
      when "PgDiff::Models::Table"
        objclass.new(objdata).tap do |table|
          # columns are instrinsically connected to database and don't need
          # to be represented as a dependency
          table.add_columns(@queries.table_columns(table.name))
          table.add_options(@queries.table_options(table.name))

          # privileges are virtual (don't have oids)
          # they are "dropped" when tables are dropped
          # but should be created (GRANT / REVOKE) explicitly when tables are created
          # they are marked as a oncreate dependency
          table.add_privileges(@queries.table_privileges(table.name))

          # only constraints and indexes have objid
          # so they should be added to world
          tconstraints = @queries.table_constraints(table.name)
          tindexes = @queries.table_indexes(table.name)

          tconstraints.each do |tc|
            @world.objects[tc["objid"]] = [tc,table]
            @world.classes[tc["objid"]] = PgDiff::Models::TableConstraint
          end

          tindexes.each do |ti|
            @world.objects[ti["objid"]] = [ti,table]
            @world.classes[ti["objid"]] = PgDiff::Models::TableIndex
          end

          table.add_constraints(tconstraints)
          table.add_indexes(tindexes)
        end
      when "PgDiff::Models::TableConstraint", "PgDiff::Models::TableIndex"
        objclass.new(objdata[0], objdata[1])
      when "PgDiff::Models::View"
        objclass.new(objdata).tap do |view|
          view.add_privileges(
            view.materialized? ?  @queries.materialized_view_privileges(view.name) :
                                  @queries.view_privileges(view.name)
          )
        end
      when "PgDiff::Models::Function"
        objclass.new(objdata).tap do |function|
          function.add_privileges(@queries.function_privileges(function.name, function.argtypes))
        end
      when "PgDiff::Models::Sequence"
        objclass.new(objdata).tap do |sequence|
          sequence.add_privileges(@queries.sequence_privileges(sequence.name))
        end
      when "PgDiff::Models::Domain"
        objclass.new(objdata).tap do |domain|
          domain.add_constraints(@queries.domain_constraints(domain.name))
        end
      else
        objclass.new(objdata)
      end
    end

    def setup
      @world   ||= (PgDiff::World[@label] = PgDiff::World.new)
      @catalog ||= PgDiff::Catalog.new(@pg, @label)
      @queries ||= PgDiff::Queries.new(@pg, @label)

      @queries.dependency_pairs.each do |dep|
        objdata  = @world.objects[dep["objid"]]

        object = case objdata
        when Hash, Array
          objclass = @world.classes[dep["objid"]]
          @world.objects[dep["objid"]] = build_object(objdata, objclass)
        when NilClass
          @world.classes[dep["objid"]] = Models::Unmapped
          @world.objects[dep["objid"]] = PgDiff::Models::Unmapped.new(dep["objid"], dep["object_identity"], dep["object_type"], @label)
        else
          objdata
        end

        chain    = (JSON.parse(dep["dependency_chain"]) rescue [])
        # chain[-1] == object
        refobjid = chain[-2]

        if refobjid
          referenced = @world.objects[refobjid]

          @world.add_dependency(
            PgDiff::Dependency.new(
              object,
              referenced,
              dep["dependency_type"]
            )
          )
        end
      end

      # objects that do not appear on dependency pairs
      @world.objects.select do |id,o|
        o.is_a?(Hash)
      end.each do |id,o|
        objdata  = o
        objclass = @world.classes[id]

        if objdata
          @world.objects[id] = build_object(objdata, objclass)
        end
      end
    end
  end
end