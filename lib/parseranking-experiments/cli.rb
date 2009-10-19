require "logger"
require "optparse"
require "yaml"


module ParserankingExperiments

  class CLI

    def self.execute(stdout, arguments=[])

      # Parse the command line.  Information from the command line will be
      # used to populate the options hash.
      options = {:format => :summary}
      parser = OptionParser.new do |opts|
        opts.banner = <<-BANNER
Manage HPSG parse ranking experiments.

Usage: #{File.basename($0)} [options] create|results|clean|generate

create name [path] [ranges]
  Create a new feature grid experiment with called 'name' with TSDB profiles
  located in 'path'.  If 'path' is unspecified, the current directory is used.
  Use the serialized 'ranges' file to specify the parameter ranges.  If this
  is not specified, generate the ranges from the profiles current existing on
  the path.  The 'ranges-output' option may be used to write this experiment's
  ranges to a separate file.

  This prints a YAML serialization of the experiment structure to STDOUT.

results experiment
  Print the current results of the experiment stored in the 'experiment' file.
  The 'format' option may be used to specify different output formats.  The
  'filter' option may be used to specify a YAML parameter ranges object used
  to filter the results that are printed.

clean experiment
   Clean up all failed profiles from the experiment stored in the
   'experiment' file.  This deletes the TSDB profiles directories and removes
   the entries from the 'experiment' file.

generate experiment
  Generate lisp command files to run the missing and failed results in the
  'experiment' file.  The 'prefix' and 'lisp-dir' options may be used to customize
  how these files are named and where they are created.  The 'filter' option
  may be used to specify a YAML parameter ranges object used to filter the
  lisp files that are generated.
BANNER
        opts.separator ""
        opts.on("-l", "--logging=LEVEL", String, "Set the logging level",
                "Default: INFO") do |arg|
          Delphin.set_log_level(eval("Logger::#{arg.upcase}"))
        end
        opts.on("-d", "--display=[yaml|summary|details]",
                [:yaml, :summary, :details],
                "Display format for experiments file",
                "Default: summary") do |arg|
          options[:format] = arg
        end
        opts.on("-r", "--ranges-output=FILE", String,
                "Serialize the ranges information") do |arg|
          options[:ranges_output] = arg
        end
        opts.on("-p", "--prefix=NAME", String,
                "Prefix to append to experiment lisp files",
                "Default: none") do |arg|
          options[:prefix] = arg
        end
        opts.on("-f", "--filter=FILE", String,
                "YAML ranges filter file") do |arg|
          if not File.file?(File.expand_path(arg))
            message_and_exit(stdout, "#{arg} is not a file.")
          end
          options[:filter] = YAML.load_file(File.expand_path(arg))
        end
        opts.on("-l", "--lisp-dir=DIR", String,
                "Directory into which to write experiment lisp files",
                "Default: the experiment profile path") do |arg|
          if not File.directory?(File.expand_path(arg))
            message_and_exit(stdout, "#{arg} is not a directory.")
          end
          options[:lisp_file_path] = File.expand_path(arg)
        end
        opts.on("-h", "--help", "Show this help message.") do
          message_and_exit(stdout, opts)
        end

        begin
          opts.parse!(arguments)
        rescue OptionParser::InvalidArgument => e
          message_and_exit(stdout, e)
        end

        # Parse the positional arguments.
        if arguments.empty?
          message_and_exit(stdout, "You must specify a command.")
        end
        options[:command] = arguments.shift

        case options[:command]
        when "create"
          name, profile_path, ranges = arguments
          if name.nil?
            message_and_exit(stdout, "You must specify an experiment name.")
          end
          options[:name] = name
          options[:profile_path] = self.verify_profile_path(profile_path)
          options[:ranges_file] = ranges
        when "results", "clean", "generate"
          if arguments.empty?
            message_and_exit(stdout,
              "You must specify the name of an experiment file.")
          end
          options[:experiment] = load_experiment_file(stdout, arguments.shift)
        else
          message_and_exit(stdout, "Invalid command #{options[:command]}.")
        end
      end # OptionParser.new

      # Perform the experiment operations.
      case options[:command]
      when "create"
        experiment = create_experiment(stdout, options[:name],
                          verify_profile_path(options[:profile_path]),
                          options[:ranges_file], options[:ranges_output])
        results(stdout, experiment, :yaml, options[:filter])
      when "results"
        results(stdout, options[:experiment], options[:format],
                options[:filter])
      when "clean"
        options[:experiment].delete_failed_profiles!
      when "generate"
        generate(stdout, options[:experiment], options[:prefix],
                         options[:lisp_file_path], options[:filter])
      end
    end # self.execute


    # Verify that the profile path specified in the command line exists and
    # normalize it.
    def self.verify_profile_path(profile_path)
      profile_path = "." if profile_path.nil?
      if not File.directory?(profile_path)
        message_and_exit(stdout, "#{profile_path} is not a directory.")
      end
      File.expand_path(profile_path)
    end


    # Load a serailized experiment file.
    def self.load_experiment_file(out, experiment_file)
      begin
        YAML.load_file(experiment_file)
      rescue Errno::ENOENT
        message_and_exit(out, "#{experiment_file} does not exist.")
      end
    end


    # Create an experiment object.
    def self.create_experiment(out, name, profile_path, ranges_file,
                               ranges_output)
      experiment = if ranges_file.nil?
        # Read an experiment from a set of TSDB profiles in a directory.
        begin
          Delphin::FeatureGridExperiment.from_profile_path(profile_path, name)
        rescue Delphin::NoProfiles => e
          message_and_exit(out, e)
        end
      else
        # Create an experiment from a profile path and a ranges file.
        ranges = begin
          YAML.load_file(ranges_file)
        rescue Errno::ENOENT
          message_and_exit(stdout, "#{ranges_file} does not exist.")
        end
        Delphin::FeatureGridExperiment.new(profile_path, name, ranges)
      end
      # Optionally serialize the ranges for this experiment to a separate
      # file.
      if not ranges_output.nil?
        open(File.expand_path(ranges_output), "w") do |file|
          file << experiment.ranges.to_yaml
        end
      end
      experiment
    end


    # Print experiment results.
    def self.results(out, experiment, format, filter)
      experiment = experiment.filtered_experiment(filter) if filter
      out.puts case format
      when :details
        experiment.to_results_details
      when :summary
        experiment
      when :yaml
        experiment.to_yaml
      else
        raise "Invalid serialization format '#{format}'."
      end
    end


    # Create lisp files to run new experiments.
    def self.generate(out, experiment, prefix, lisp_file_path, filter)
      experiment = experiment.filtered_experiment(filter) if filter
      lisp_file_path = experiment.profile_path if lisp_file_path.nil?
      lisp_files = []
      # Generate the lisp command files.  Each lisp file will be used to run a
      # parse ranking experiment for a single set of parameters.
      experiment.each_incomplete_experiment_lisp_file do |filename, lisp_file|
        filename = "#{prefix}.#{filename}" if not prefix.nil?
        filename = File.join(lisp_file_path, filename) + ".lisp"
        File.open(filename, "w") {|file| file << lisp_file}
        lisp_files << filename
      end
      # Generate a master list of all the files we just created.
      master_list = "#{experiment.name}.files"
      master_list = "#{prefix}.#{master_list}" if not prefix.nil?
      master_list = File.join(lisp_file_path, master_list)
      File.open(master_list, "w") do |file|
        file << lisp_files.join("\n") << "\n"
      end
      out.puts "Generated #{lisp_files.length} lisp files.  " +
               "Master list in #{master_list}."
    end


    # Display an error message and exit.
    def self.message_and_exit(out, msg)
      out.puts msg
      exit
    end

  end # CLI

end
