module Delphin

  # Abstract base class for all exceptions raised by this file.
  #
  # Derived classes must define a to_short_s error function, which returns a
  # terse description of the error without the actual profile path.  They may
  # also implement a to_s which gives a more verbose description that includes
  # the profile path.
  class InvalidProfileException < Exception
    def to_short_s
      "Invalid profile"
    end
  end


  class MissingDataFile < InvalidProfileException
    def initialize(name, profile)
      @name = name
      @directory = profile.directory
    end

    def to_s
      "Missing data file for table '#{@name}' in #{@directory}."
    end
    
    def to_short_s
      "Missing data file for table '#{@name}'"
    end
  end


  class EmptyDataFile < InvalidProfileException
    def initialize(name, profile)
      @name = name
      @profile = profile
    end

    def to_s
      "Empty data file for table '#{@name}' in #{@profile.directory}."
    end
    
    def to_short_s
      "Empty data file for table '#{@name}'"
    end
  end


  class MissingRelationsFile < InvalidProfileException
    def initialize(directory)
      @directory = directory
    end
    
    def to_s
      "Missing 'relations' file in #{@directory}."
    end
    
    def to_short_s
      "Missing 'relations' file"
    end
  end


  class InvalidRelationsFile < InvalidProfileException
    def initialize(filename, linenum, line)
      @filename = filename
      @linenum = linenum
      @line = line
    end

    def to_s
      "Invalid 'relations' file: line #{@linenum} #{@filename}\n#{@line}"
    end
    
    def to_short_s
      "Invalid 'relations' file"
    end
  end


  # A TSDB profile
  class Profile
    attr_reader :directory, :relations

    def initialize(directory)
      @directory = directory
      begin
        @relations = open(File.join(directory, "relations")) do |file|
          RelationsFile.new(file)
        end
      rescue Errno::ENOENT
        raise MissingRelationsFile.new(directory)
      end
    end

    def inspect
      "#{self.class}(#{directory})"
    end

    def to_s
      inspect
    end

    # A list of all the tables in the profile
    def tables
      @relations.keys
    end

    # Open the specified table file.
    def [](name)
      ProfileTable.new(self, name, @relations[name])
    end

    # Retun mean, standard deviation,and range structure for numeric values in
    # the specified field.
    def statistics(table, field)
      s = self[table].collect {|r| r[field].to_f}
      n = s.length
      raise EmptyDataFile.new(table, self) if n.zero?
      mean = (s.inject(0) {|sum, x| sum + x})/n
      n = n-1 if n > 1
      sdev = Math.sqrt((s.inject(0) {|sum, x| sum + (x-mean)**2})/n)
      range = s.max - s.min
      Statistics.new(mean, sdev, range)
    end
  end


  # A data table in a TSDB profile.
  class ProfileTable
    include Enumerable

    attr_reader :profile, :name, :schema, :filename

    def initialize(profile, name, schema)
      @profile = profile
      @name = name
      @schema = schema
      # Find the table containing this table.  It may be gzipped.      
      filename = File.join(profile.directory, name)
      gzname = filename + ".gz"
      if File.exist?(filename)
        @filename = filename
        @file = open(filename)
      elsif File.exist?(gzname)
        @filename = gzname
        @file = Zlib::GzipReader.open(gzname)
      else
        raise MissingDataFile.new(@name, @profile)
      end
    end

    def inspect
      "#{self.class}(#{name}) in #{profile}"
    end

    def to_s
      inspect
    end

    # Enumerate the records in this table.
    def each
      @file.each do |line|
        yield @schema.record(line.strip!)
      end
    end
  end # ProfileTable


  # A database schema table in a profile.
  #
  # This is a list of field labels and their types.
  class ProfileTableSchema < Array
    attr_reader :name, :keys, :partials

    def initialize(init_name)
      @name = init_name
      @keys = Set.new
      @partials = Set.new
    end

    def inspect
      "ProfileTableSchema(#{name})"
    end

    # The string representation is identical to what appears in the relations
    # file.
    def to_s
      "#{name}:\n" + collect do |field|
        s = "  #{field.label} :#{field.type}"
        s += " :key" if is_key?(field.label)
        s += " :partial" if is_partial?(field.label)
        s
      end.join("\n")
    end

    # Generate a data record from a line of text.
    #
    # A data record is a hash of field labels to values.
    def record(text)
      data_fields = text.split(/@/)
      field_names = collect {|f| f.label}
      field_types = collect {|f| f.type}
      # Do type conversion if the field is of type integer.
      data_fields = field_types.zip(data_fields).collect do |type, data|
        case type
        when "integer"
          data.to_i
        else
          data
        end
      end
      Hash[*field_names.zip(data_fields).flatten]
    end

    # Add a new field and type.
    def add_field(label, type, key = false, partial = false)
      self.push(Struct.new(:label, :type).new(label, type))
      @keys.add(label) if key
      @partials.add(label) if partial
    end

    # Is the specified label a key?
    def is_key?(label)
      @keys.member?(label)
    end

    # Is the specified label a partial?
    def is_partial?(label)
      @partials.member?(label)
    end
  end # ProfileTableSchema


  # A file that contains a set of database schema tables.
  #
  # This object is a hash of ProfileTableSchema objects indexed by table name.
  class RelationsFile < Hash
    def initialize(file)
      state = :outside_table
      table_name = nil
      file.each_with_index do |line,i|
        # Remove comments and surrounding whitespace.
        line.sub!(/#.*/, "")
        line.strip!
        case state
        when :inside_table
          if line.empty?
            state = :outside_table
          elsif line =~ /^(\S+)\s+:(\w+)(\s+:key)?(\s+:partial)?$/
            # E.g. parse-id :integer :key
            field, type = line.split
            self[table_name].add_field($1, $2, !$3.nil?, !$4.nil?)
          else
            raise InvalidRelationsFile.new(filename, i+1, line)
          end
        when :outside_table
          next if line.empty?
          if line =~ /(\S+):/
            # E.g. item:
            table_name = $1
            self[table_name] = ProfileTableSchema.new(table_name)
            state = :inside_table
          else
            raise InvalidRelationsFile.new(filename, i+1, line)
          end
        end
      end # each_with_index
    end # initialize

    # Print out a relations file
    def to_s
      values.map {|t| t.to_s}.join("\n\n")
    end # to_s
  end # RelationsFile


  # Statistics for a set of numbers.
  class Statistics < Struct.new(:mean, :sdev, :range)
  end

end