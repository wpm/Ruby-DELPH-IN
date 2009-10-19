require "erb"
require "pathname"

module Delphin

  # Convert Ruby's stringfication of numbers in scientific notation to
  # Lisp's.
  #
  # Lisp removes leading zeros from the exponent, e.g. '1.0e-1' instead of
  # '1.0e-01'.
  def Delphin.lisp_scientific_notation(x)
    sprintf("%.1e", x).sub(/0(\d)$/, '\1')
  end


  # Abstract base class for all exceptions raised by this file.
  class ParseRankingException < Exception
  end


  # Raised by FeatureGridExperiment.from_profile_path when there are no
  # profiles of matching the given experiment name and path.
  class NoProfiles < ParseRankingException
    def initialize(profile_path, name)
      @profile_path = profile_path
      @name = name
    end
    
    def to_s
      "No '#{@name}' profiles in #{@profile_path}."
    end
  end


  # Return a list of feature grid experiments corresponding to all the
  # profiles appearing in a specified directory.
  #
  # [<em>profile_path</em>] a directory containing output profiles
  def Delphin.experiments_from_directory(profile_path)
    # Collect all the profile info in the specified path into a hash indexed
    # by experment name.
    profiles = Hash.new {[]}
    Dir.entries(profile_path).select do |d|
      # Find all the directories in the profile path excluding '.' and '..'.
      File.directory?(File.join(profile_path, d)) and d !~ /^\.+$/
    end.each do |d|
      begin
        p = ProfileInfo.from_s(d)
        profiles[p.name] <<= p
      rescue ArgumentError => e
        # This is not a profile directory.  Ignore it.
      end
    end
    # Create experiments from these profiles.
    experiments = []
    profiles.each_key do |name|
      # Create parameter ranges out of this profile info.
      ranges = profiles[name].map do |p|
        ParameterRanges.from_hash(p)
      end.inject { |mem, r| mem += r }
      # Create an experiment with these ranges.
      experiments << FeatureGridExperiment.new(profile_path, name, ranges)
    end
    experiments
  end


  # A set of parse ranking experiments for a single corpus over a range of
  # machine learning feature values.
  class FeatureGridExperiment
    @@keep_together = ["relative-tolerance", "variance"]
    @@erb_template =<<-EOTEXT
; <%= filename %>.lisp

(in-package :tsdb)

(load "parsing.lisp")

(batch-experiment
<%= lisp_parameters %>)
EOTEXT

    # The path to the TSDB profiles containing the experiment results.
    attr_reader :profile_path
    # The name of this experiment
    attr_reader :name
    # A ParameterRanges object
    attr_reader :ranges
    # The experiment results, indexed by profile info
    attr_reader :results

    # Create a grid experiment from a set of parameter ranges
    #
    # [<em>profile_path</em>] a directory containing output profiles
    # [_name_] the experiment name, e.g. jhpstg
    # [_ranges_] a ParameterRanges object
    def initialize(profile_path, name, ranges)
      @profile_path = profile_path
      @name = name
      @ranges = ranges
      # 'nfold' and 'niterations' are experiment parameters, but they are not
      # reflected in the profile names so just define them here.
      @results = {"nfold" => 10, "niterations" => 2}
      gather_results!
    end

    # Create a grid experiment from an existing set of profile directories.
    #
    # [<em>profile_path</em>] a directory containing output profiles
    # [_name_] the experiment name, e.g. jhpstg
    def self.from_profile_path(profile_path, name)
      # Find all the directories in the specified path whose names begin with
      # '[name]'.
      profiles = []
      results_glob = File.join(profile_path, "\\[#{name}\\]*")
      Pathname.glob(results_glob).select {|d| d.directory?}.each do |d|
        LOGGER.debug("Found profile #{d}")
        begin
          profiles << ProfileInfo.from_s(File.basename(d))
        rescue ArgumentError => e
          LOGGER.error("#{d} is not a profile directory name")
          raise e
        end
      end
      raise NoProfiles.new(profile_path, name) if profiles.empty?
      # Parse the profile names and combine them into a single set of
      # parameter ranges.  Only retain those parameters that ranges over
      # multiple values.
      ranges = profiles.map do |p|
        ParameterRanges.from_hash(p)
      end.inject { |mem, r| mem += r }
      # Create the object.
      self.new(profile_path, name, ranges)
    end

    # Display the name, path, number of grid points, and table of ranges.
    def to_s
      "#{inspect}\n#{ranges}"
    end

    # Display the name, path, and number of grid points.
    def inspect
      completed, missing, failed = [completed_experiments.length,
                                    missing_experiments.length,
                                    failed_experiments.length]
      "Feature Grid: #{name}\n" +
      "#{ranges.length} grid points: " +
      "#{completed} completed, #{missing} missing, #{failed} failed"
    end

    # Summarize experimental results in descending order of mean accuracy
    # along with lists of missing and failed experiments.
    def to_results_details
      # Display completed experiment statistics along with their profile files
      # in descending order of mean accuracy.
      completed = completed_experiments.sort_by do |profile_info|
        [-self[profile_info].first.mean, profile_info.to_s]
      end.map do |profile_info|
        stats = self[profile_info][0]
        timestamp = self[profile_info][1]
        "#{stats.to_a.join(',')} #{profile_info} (#{timestamp})"
      end
      # Display failed experiment profile names along with the reason for the
      # failure.
      failed = failed_experiments.sort_by do |profile_info|
        profile_info.to_s
      end.map do |profile_info|
        "#{profile_info}\n\t#{self[profile_info][0].to_short_s}"
      end
      # Display the names of missing profiles.
      missing = missing_experiments.sort_by do |profile_info|
        profile_info.to_s
      end.map { |profile_info| profile_info.to_s }
      "#{inspect}\n\n"+(["Completed Experiments"] + completed +
       ["Failed Experiments"] + failed +
       ["Missing Experiments"] + missing).join("\n")
    end

    # Create a copy of this experiment object, removing experiment
    # configurations not specified by _filter_.
    #
    # [_filter_] a ParameterRanges object
    def filtered_experiment(filter)
      LOGGER.debug("Filter experiment with:\n#{filter}")
      e = clone
      # Filter the parameter ranges.
      e.ranges = e.ranges.filtered_ranges(filter)
      # Remove all results that are not in the parameter ranges.
      e.results = {}
      e.each_results_profile_info do |profile_info|
        if self.has_key?(profile_info)
          e[profile_info] = self[profile_info]
        end
      end
      e
    end

    # Enumerate over lisp parameter files for all the missing and failed
    # experiments tracked by this object.  Yield a filename part and its lisp
    # contents.
    #
    # [<em>erb_template</em>] the ERB template for the lisp file.  See the
    #                         default class <em>erb_template</em> for an
    #                         example of the template.
    def each_incomplete_experiment_lisp_file(erb_template = @@erb_template)
      erb_template = ERB.new(erb_template)
      each_incomplete_experiment_parameter_ranges do |ranges|
        # Generate the filename from the ranges over which the paramters vary.
        filename = ranges.to_filename_s(varable_parameters)
        filename = filename.empty? ? name : "#{name}.#{filename}"
        # Generate the lisp code that will be written to the experiment grid
        # file.
        lines = [":source", ":skeleton", ":prefix"].map do |p|
          "#{p} \"#{name}\""
        end
        lines += [":type :mem", ranges.to_lisp]
        lisp_parameters = lines.join("\n")
        yield [filename, erb_template.result(binding)]
      end
    end

    # Delete the output profiles directories of all failed rankings for this
    # experiment and remove the corresponding entries from the results table.
    def delete_failed_profiles!
      failed_experiments.each do |profile_info|
        profile = File.join(profile_path, profile_info.to_s)
        LOGGER.info("Delete #{profile}")
        FileUtils.rm_rf(profile)
        @results.delete(profile_info)
      end
    end

    # Look up results by profile information.
    #
    # [<em>profile_info</em>] a ProfileInfo object or a string representation
    #                         of one for an experiment in this grid
    def [](profile_info)
      profile_info = profile_info.to_s if profile_info.is_a?(ProfileInfo)
      @results.fetch(profile_info)
    end


    # If the specified results profile in this experiment?
    #
    # [<em>profile_info</em>] a ProfileInfo object or a string representation
    #                         of one for an experiment in this grid
    def has_key?(profile_info)
      profile_info = profile_info.to_s if profile_info.is_a?(ProfileInfo)
      @results.has_key?(profile_info)
    end

    # All the missing experiments.
    #
    # This returns a list of string representations of ProfileInfo objects.
    def missing_experiments
      missing = []
      each_results_profile_info do |profile_info|
        missing << profile_info.to_s if missing?(profile_info)
      end
      missing
    end

    # All the completed experiments.
    #
    # This returns a list of string representations of ProfileInfo objects.
    def completed_experiments
      completed = []
      @results.each_key do |profile_info|
        completed << profile_info if result_type(profile_info, Struct)
      end
      completed
    end

    # All the failed experiments.
    #
    # This returns a list of string representations of ProfileInfo objects.
    def failed_experiments
      failed = []
      @results.each_key do |profile_info|
        failed << profile_info if result_type(profile_info,
                                              InvalidProfileException)
      end
      failed
    end

    protected

    # Set the ranges hash.  This is used by filtered_experiment.
    def ranges=(r)
      @ranges = r
    end

    # Set the results hash.  This is used by filtered_experiment.
    def results=(r)
      @results = r
    end

    # Create a hash of experiment results indexed by profile information.
    #
    # The result is an ordered pair
    #
    #    [_info_, _time_]
    #
    # For a successful result, _info_ is is a strucutre containing the mean,
    # sdev, and range of the f-accuracy field of the fold table and _time_ is
    # the last modification time of the fold table.  For an unsuccessful
    # result, _info_ is an exception nd _time_ is _nil_.  No entry in the
    # results hash will be created if the output profile directory does not
    # exist.
    def gather_results!
      each_results_profile_info do |profile_info|
        LOGGER.debug("Gathering results from #{profile_info}")
        path = File.join(profile_path, profile_info.to_s)
        # If the directory doesn't exist, the experiment is missing.
        next if not File.directory?(path)
        begin
          self[profile_info] =
            [Profile.new(path).statistics("fold", "f-accuracy"),
             File.mtime(path)]
        rescue InvalidProfileException => e
          # If there is something wrong with the profile directory, the
          # experiment failed.
          self[profile_info] = [ e, nil]
        end
      end
    end

    # Is the experiment result for the specified profile of the specified
    # type?  This is called by the public completed? and failed? methods.
    #
    # [<em>profile_info</em>] a ProfileInfo object or its stringification
    # [_klass_] a Class
    def result_type(profile_info, klass)
      not missing?(profile_info) and self[profile_info][0].is_a?(klass)
    end

    # Associate an experiment result with profile information.
    #
    # [<em>profile_info</em>] a ProfileInfo object or a string representation
    #                         of one for an experiment in this grid
    def []=(profile_info, result)
      profile_info = profile_info.to_s if profile_info.is_a?(ProfileInfo)
      @results[profile_info] = result
    end

    # Enumerate over all the path names of the results profiles corresponding
    # to the features ranges for this experiment.  For each feature
    # combination yield the corresponding ProfileInfo object.
    def each_results_profile_info
      ranges.each_value_combination do |range|
        profile_info = ProfileInfo.new(name)
        # Each parameter will have only one value.
        range.each do |parameter, values|
          profile_info[parameter] = values.first
        end
        yield profile_info
      end
    end

    # Enumerate over parameter ranges of all the missing and failed
    # experiments tracked by this object.
    def each_incomplete_experiment_parameter_ranges
      # Collect the ProfileInfo objects for all the missing and failed
      # experiments into a single ParameterRanges object.
      incomplete_experiments = 
      (missing_experiments + 
       failed_experiments).inject(ParameterRanges.new) do |ranges, profile_info_name|
        LOGGER.debug("Incomplete experiment #{profile_info_name}")
        profile_info = ProfileInfo.from_s(profile_info_name)
        ranges += ParameterRanges.from_hash(profile_info)
      end
      # Enumerate over each parameter value combination and yield the
      # corresponding profile information.  Keep the machine learning
      # parameters together in the same lisp file.
      incomplete_experiments.each_value_combination(*@@keep_together) do |ranges|
        yield ranges
      end
    end

    # A list of parameters that take on different values in this experiment. 
    # This is a subset of the keys of ranges.
    def varable_parameters
      ranges.multivalue_ranges
    end

    # Is this experiment missing?
    #
    # [<em>profile_info</em>] a ProfileInfo object or its stringification
    def missing?(profile_info)
      profile_info = profile_info.to_s if profile_info.is_a?(ProfileInfo)
      not results.has_key?(profile_info)
    end

  end # FeatureGridExperiment
  

  # The name and feature values of a TSDB profile.
  #
  # The string representation is one of those ungainly things with features
  # surrounded by square brackets and lots of spaces in the middle.
  class ProfileInfo < Hash
    # Mapping of strings in profile names to lisp feature names.
    #
    # Dereferencing this hash with a key it doesn't have returns that key.
    @@lisp_name  = Hash.new {|h,k| k}.merge({
                    "AE" => "active-edges-p",
                    "CW" => "constituent-weight",
                    "GP" => "grandparenting",
                    "LEX" => "lexicalization-p",
                    "LM" => "lm-p",
                    "NB" => "ngram-back-off-p",
                    "NS" => "ngram-size",
                    "NT" => "ngram-tag",
                    "PT" => "use-preterminal-types-p",
                    "RT" => "relative-tolerance",
                    "RS" => "random-sample-size",
                    "VA" => "variance"
                    })

    # The profile name, e.g. jhpstg
    attr_reader :name

    # [_name_] the profile name, e.g. jhpstg
    def initialize(name)
      @name = name
    end

    # Extract the profile information from the directory name.
    #
    # [_s_] directory name string
    def self.from_s(s)
      fields = s.split
      prefix = fields.shift
      if (prefix =~ /\[(.*?)\]/) == nil
        raise ArgumentError.new("Invalid prefix field #{prefix} in '#{s}'")
      end
      f = self.new($1)
      fields.each do |field|
        name, value = case field
        when /FT\[.*?\]/ # e.g. FT[:::1]
          # TODO Correctly parse the FT[:::] field.  For now just ignore it.
          next
        when /(\w+)\[(.*?)\]/ # e.g. CW[2], VA[1.0e+0]
          name = $1
          raw_value = $2
          value = case raw_value
          when /^\d+$/ # e.g. NS[4]
            raw_value.to_i
          when /^\d+\.\d+e[+-]\d+$/ # e.g AT[1.0e-20], VA[1.0e+0]
            raw_value.to_f
          else
            raw_value
          end
          [name, value]
        when /([+-])(\w+)/ # e.g. +PT, -LEX
          [$2, $1 == "+" ? true : false]
        else
          raise ArgumentError.new("Invalid field #{field} in '#{s}'")
        end
        f[@@lisp_name[name]] = value
      end
      f
    end

    # A string in the format of the awkward directory names used for TSDB
    # profile directories.
    #
    # e.g. [jhpstg] GP[4] +PT -LEX CW[] +AE NS[4] NT[type] +NB LM[0]
    # FT[:::1] RS[] MM[tao_lmvm] MI[5000] RT[1.0e-8] AT[1.0e-20] VA[]
    # PC[100]
    def to_s
      # Lisp and Ruby have slightly different stringification for numbers in
      # scientific notation.
      rt, at, va = [self[@@lisp_name['RT']],
                    self[@@lisp_name['AT']],
                    self[@@lisp_name['VA']]].map do |value|
        value.is_a?(Float) ? Delphin.lisp_scientific_notation(value) : value
      end
      "[#{name}] " +
      "GP[#{self[@@lisp_name['GP']]}] " +
      "#{self[@@lisp_name['PT']] ? '+':'-'}PT " +
      "#{self[@@lisp_name['LEX']] ? '+' : '-'}LEX " +
      "CW[#{self[@@lisp_name['CW']]}] " +
      "#{self[@@lisp_name['AE']] ? '+':'-'}AE " +
      "NS[#{self[@@lisp_name['NS']]}] " +
      "NT[#{self[@@lisp_name['NT']]}] " +
      "#{self[@@lisp_name['NB']] ? '+':'-'}NB " +
      "LM[#{self[@@lisp_name['LM']]}] " +
      "FT[:::1] " + # TODO Correctly handle FT paramter stringification
      "RS[#{self[@@lisp_name['RS']]}] " +
      "MM[#{self[@@lisp_name['MM']]}] " +
      "MI[#{self[@@lisp_name['MI']]}] " +
      "RT[#{rt}] "+
      "AT[#{at}] "+
      "VA[#{va}] "+
      "PC[#{self[@@lisp_name['PC']]}]"
    end

  end # ProfileInfo


  # Ranges over which parse ranking features take their values.
  #
  # This is a hash of permissible value arrays indexed by parameter name.
  class ParameterRanges < Hash

    # Maxent feature values are not printed to lisp files.
    @@maxent_features = ["MM", "MI", "RT", "AT", "VA", "PC"]
    
    # Create parameter ranges from hash.  Single-item hash values are
    # converted to arrays as needed.
    def self.from_hash(h)
      r = self.new
      h.each do |parameter, values|
        r[parameter] = values.is_a?(Array) ? values : [values]
      end
      r
    end

    # Hash stringification labeled with the name of this class.
    def inspect
      "Parameter Ranges #{super}"
    end

    # Print a table of parameters and ranges.
    def to_s
      sorted_keys.map do |parameter|
        "#{parameter} = #{self[parameter].inspect}"
      end.join("\n")
    end

    # Print all the parameters and values on a single line of text suitable
    # for use in a filename.
    #
    # [_filter_] a set of parameter values to include in the name
    #
    # If _filter_ is not specified, all parameter values are included in the
    # name.
    def to_filename_s(filter = nil)
      filter ||= Set.new(keys)
      sorted_keys.select do |parameter|
        filter.include?(parameter)
      end.map do |parameter|
        ([parameter] + self[parameter].map { |value| value.to_s }).join("_")
      end.join(".")
    end

    # Write these parameters in a format that can be incorporated into Lisp
    # code.
    #
    # If _filter_ is specified, only those parameters in _filter_ will be
    # printed.
    #
    # [_filter_] set of parameters
    def to_lisp(filter = nil)
      lisp_parameters = filter ? filter : keys
      lisp_parameters -= @@maxent_features
      sorted_keys.select do |parameter|
        lisp_parameters.include?(parameter)
      end.map do |parameter|
        range = self[parameter]
        range = range.map do |value|
          if value.is_a?(Float)
            value = Delphin.lisp_scientific_notation(value)
          end
          case value
          # Convert individual values to lisp string representations.
          when nil,false,""
            "nil"
          when true
            "t"
          else
            value.to_s
          end
        end
        # Convert ranges with more than one element to lisp lists.
        range = range.length == 1 ? range : "'(#{range.join(' ')})"
        ":#{parameter} #{range}"
      end.join("\n")
    end

    # The total number of feature value combinations.
    def length
      keys.inject(1) { |n, parameter| n *= self[parameter].length }
    end

    # Combine this with another set of ranges.
    #
    # [_other_] a ParameterRanges object
    def +(other)
      sum = self.class.new
      # Combine the values.
      each { |parameter, values| sum[parameter] = Set[*values] }
      other.each do |parameter, values|
        if sum.has_key?(parameter)
          sum[parameter] += Set[*values]
        else
          sum[parameter] = Set[*values]
        end
      end
      # Convert to sets of values back to lists.
      sum.each_key { |parameter| sum[parameter] = sum[parameter].to_a  }
      sum
    end

    # Return a filtered copy of this object.
    #
    # f(x,y) x filtered by y is a set of parameter ranges f(x,y) where the
    # parameters are equal to the parameters of x, f(x,y)[v] = y[v] for all v
    # in x.keys and y.keys and f(x,y)[v] = x[v] for all v not in y.keys.
    #
    # [_filter_] a ParameterRanges object
    def filtered_ranges(filter)
      ranges = clone
      ranges.each do |parameter, values|
        if filter.keys.include?(parameter)
          ranges[parameter] = filter[parameter]
        end
      end
      ranges
    end

    # Remove all the parameters from this object that only have a single
    # value.
    def remove_single_value_parameters!
      each do |parameter, values|
        delete(parameter) unless values.length > 1
      end
    end

    # An array of the parameters that have more than one value specified in
    # their range.
    def multivalue_ranges
      keys.select {|parameter| self[parameter].length > 1 }
    end

    # Enumerate over all possible value combinations within the specified
    # ranges.  This yields ParameterRanges objects whose range values are
    # subsets of those in this object.
    #
    #     > r = Delphin::ParameterRanges["a", [1,2], "b", [3,4]]
    #     => {"a"=>[1, 2], "b"=>[3, 4]}
    #     > c = []; r.each_value_combination {|x| c << x}; c.inspect
    #     Parameter Ranges {"a"=>[1], "b"=>[3]}
    #     Parameter Ranges {"a"=>[1], "b"=>[4]}
    #     Parameter Ranges {"a"=>[2], "b"=>[3]}
    #     Parameter Ranges {"a"=>[2], "b"=>[4]}
    #
    # The optional arguments may be used to specify the names of parameters
    # whose values are to be kept together.
    #
    #     > r = Delphin::ParameterRanges["a", [1,2], "b", [3,4], "c", [5,6]]
    #     => Parameter Ranges {"c"=>[5, 6], "a"=>[1, 2], "b"=>[3, 4]}
    #     > r.each_value_combination("c") {|x| puts x.inspect}
    #     Parameter Ranges {"c"=>[5, 6], "a"=>[1], "b"=>[3]}
    #     Parameter Ranges {"c"=>[5, 6], "a"=>[1], "b"=>[4]}
    #     Parameter Ranges {"c"=>[5, 6], "a"=>[2], "b"=>[3]}
    #     Parameter Ranges {"c"=>[5, 6], "a"=>[2], "b"=>[4]}
    def each_value_combination(*keep_together)
      # Build a parameter ranges object out of the keys whose values we will
      # keep together.
      together_ranges = self.class.new
      keep_together.each do |p|
        unless keys.include?(p)
          raise ArgumentError.new("#{p} not in parameter list")
        end
        together_ranges[p] = self[p]
      end
      # Create new parameter ranges objects by taking the cross products of
      # the ranges in this one.
      cross_p = (keys - keep_together).sort_by {|k| k.to_s}
      value_vectors = if cross_p.length > 1
        # Take the cross product of all parameter ranges in key order to get
        # vectors of parameter values.
        rest = cross_p[1..-1].collect { |p| self[p] }
        value_vector = self[cross_p.first].product(*rest)
      else
        # Special case: don't take cross products if there is only one key.
        self[cross_p.first].map { |value| [value] }
      end
      # Pair these value vectors with the parameter names to create new
      # parameter ranges objects.  Yield the new objects, adding on any ranges
      # kept together.
      value_vectors.each do |value_vector|
        ranges = self.class.new
        value_vector.map! { |v| [v] } # Convert single values to ranges.
        cross_p.zip(value_vector).each do |parameter, range|
          ranges[parameter] = range
        end
        yield ranges + together_ranges
      end
    end

    protected

    # Sort keys by the number of associated values and then by name.
    def sorted_keys
      keys.sort_by { |parameter| [-self[parameter].length, parameter.to_s] }
    end

  end # ParameterRanges

end