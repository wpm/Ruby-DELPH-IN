#--
# Add lib/delphin to the include path if it is not there already.
#++
$:.unshift(File.dirname(__FILE__)) unless
  $:.include?(File.dirname(__FILE__)) || $:.include?(File.expand_path(File.dirname(__FILE__)))


require "delphin/parseranking"
require "delphin/tsdb"

require "facets"
require "logger"
require "set"


module Delphin
  VERSION = '1.0.1'
  
  # Create the logger and set its default log level to ERROR.  This function
  # is called when the module is loaded.
  def Delphin.initialize_logger
    logger = Logger.new(STDERR)
    logger.level = Logger::ERROR
    logger.datetime_format = "%Y-%m-%d %H:%M:%S"
    logger
  end
  
  # Logger used by all objects in this module.  This is initialized at module
  # load time.  The default log level is ERROR.
  LOGGER = initialize_logger
  
  # Set the logging level.  For example:
  #
  #   > Delphin.set_log_level(Logger::DEBUG)
  def Delphin.set_log_level(level)
    Delphin::LOGGER.level = level
  end

  private_class_method :initialize_logger

end