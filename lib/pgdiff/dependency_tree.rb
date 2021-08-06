module PgDiff
  class DependencyTree
    attr_reader :add, :remove, :change

    def initialize
      @add     = Hash.new(false)
      @remove  = Hash.new(false)
      @change  = Hash.new(false)

      # last operation
      @lastop  = Hash.new(:noop)
      @ops     = []
    end

    def set_op(node, op, opts = {})
      if @lastop[node.gid] == op
        return true
      else
        @ops << { node: node, op: op }.merge(opts)
        @lastop[node.gid] = op
        return false
      end
    end

    def get_op(node)
      @lastop[node.gid]
    end

    def self._prerequisites(node, p = [], c = Set.new)
      return if p.include?(node)

      c.add(p + [node])

      node.dependencies.i_depend_on.referenced.each do |dependency|
        self._prerequisites(dependency, p + [node], c)
      end
    end

    def self.prerequisites(node)
      p = []
      c = Set.new
      _prerequisites(node, p, c)
      parents = Hash.new

      c.each do |chain|
        0.upto(chain.length - 1) do |idx|
          parents[chain[idx]] ||= Set.new
          parents[chain[idx]]  = parents[chain[idx]] | Set.new(chain[idx..-1])
        end
      end

      parents.each{|k,v| v.delete(k) }

      parents.sort_by{|k,v| v.length}.map(&:first).reject{|n| n.gid == node.gid }
    end

    def self._dependencies(node, p = [], c = Set.new, condition = proc {})
      return if p.include?(node)

      c.add(p + [node])

      node.dependencies.others_depend_on_me.by_condition(condition).objects.each do |dependency|
        self._dependencies(dependency, p + [node], c, condition)
      end
    end

    def self.dependencies(node, condition = proc {})
      p = []
      c = Set.new
      _dependencies(node, p, c, condition = proc {})
      children = Hash.new

      c.each do |chain|
        0.upto(chain.length - 1) do |idx|
          children[chain[idx]] ||= Set.new
          children[chain[idx]]  = children[chain[idx]] | Set.new(chain[idx..-1])
        end
      end

      children.each{|k,v| v.delete(k) }

      children.sort_by{|k,v| v.length}.map(&:first).reject{|n| n.gid == node.gid }
    end

    def _add(node, added = Hash.new)
      return if added[node.gid] = true

      self.class.prerequisites(node).each do |prior|
        added[prior.gid] = true
        _add(prior, added)
      end

      added[node.gid] = true

      self.class.dependencies(node, proc{|d| d.type == "oncreate" }).each do |dep|
        added[dep.gid] = true
        _add(dep, added)
      end
    end

    def _remove(node)
      return if @lastop[node.gid] == :remove

      self.class.dependencies(node, proc{|d| d.type == "internal" }).map do |prior|
        set_op(prior, :remove)
        _remove(prior)
      end

      set_op(node, :remove)
    end


    def tree_for(world)
      added = Hash.new

      world.objects.values.map do |node|
        _add(node, added)
      end

      added
    end


    def _diff(source, target)
      source_tree   = tree_for(source).keys
      target_tree   = tree_for(target).keys
      interspersed  = intersperse(source_tree, target_tree).reduce(Hash.new) do |acc, member|
        sobject = source.find_by_gid(member)
        tobject = target.find_by_gid(member)

        if sobject && tobject && sobject.to_s == tobject.to_s
          acc
        else
          acc.merge({ member => [
            sobject,
            tobject
          ]})
        end
      end.select{|k,(s,t)| s || t }
    end

    def intersperse(a, b)
      s   = Set.new
      idx = 0

      loop do
        s.add(a[idx]) if idx < a.length
        s.add(b[idx]) if idx < b.length

        idx += 1
        break if idx > [ a.length, b.length ].max
      end
      s
    end

    def diff(source, target)
      @ops = []

      puts "Initiating diff"
      binding.pry
      common        = Set.new(source.objects.values.map(&:gid)) & Set.new(target.objects.values.map(&:gid))
      to_be_added   = Set.new(source.objects.values.map(&:gid)) - Set.new(target.objects.values.map(&:gid))
      to_be_removed = Set.new(target.objects.values.map(&:gid)) - Set.new(source.objects.values.map(&:gid))

      # Change these
      puts "Fetching common objects that changed"
      common.each do |common_object_gid|
        sobject = source.find_by_gid(common_object_gid)
        tobject = target.find_by_gid(common_object_gid)

        if tobject.to_s != sobject.to_s
          sobject.changeset(tobject).each do |gid, options|
            case options[:op]
            when :add
              _add(source.find_by_gid(gid))
            when :remove
              _remove(target.find_by_gid(gid))
            when :rename
              self.class.dependencies(target.find_by_gid(gid), proc{|d| true }).each do |prior|
                set_op(prior, :remove)
                _remove(prior)
              end

              set_op(source.find_by_gid(options[:name]), options[:op], { from: target.find_by_gid(gid) })

              self.class.dependencies(source.find_by_gid(options[:name]), proc{|d| true }).each do |dep|
                set_op(dep, :add)
                _add(dep)
              end
            else
              set_op(source.find_by_gid(gid), options[:op], { from: target.find_by_gid(gid) })
            end
          end
        end
      end

      # Add these
      puts "Fetching objects from source that should be added to target"
      to_be_added.each do |added_gid|
        _add(source.find_by_gid(added_gid))
      end

      # Remove these
      puts "Fetching objects from source that should be removed from target"
      to_be_removed.each do |removed_gid|
        _remove(target.find_by_gid(removed_gid))
      end
      @ops
      # PgDiff::Diff.new(self, source, target)
    end
  end
end