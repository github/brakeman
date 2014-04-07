require 'digest'

class CustomCheck < Brakeman::BaseCheck
  class DuplicateCheckError < StandardError; end
  class BadCheckAttribute < StandardError; end

  ANY_MODEL_TARGET_TOKEN = :BRAKEMAN_ANY_MODEL
  ALL_ARGUMENTS_TOKEN     = :ALL

  class << self
    attr_accessor :config

    # Create a new class of CustomCheck with the given configuration and add it
    # to Brakeman, Brakeman::Checks, and Brakeman::WarningCodes::Codes.
    #
    # config - A Hash configuration for the custom check.
    #          :name           - The symbol name of the check. Must be in
    #                            CamelCase.
    #          :description    - A string describing the check.
    #          :warning_symbol - A symbol describing the check.
    #          :warning_code   - An integer code to reference the check by.
    #                            Must be globally unique. (Optional)
    #          :targets        - An Array of Symbol method targets to look for.
    #                            A special symbol, :BRAKEMAN_ANY_MODEL, can be
    #                            included, meaning that all application models
    #                            will be treated as targets. (Deafult nil)
    #          :methods        - An Array of Symbol methods to look for or a
    #                            Hash of method_name => [arg_positions].
    #                            Only the argument positions specified will be
    #                            checked. A special value of :ALL can be given
    #                            meaning that all arguments should be checked.
    #
    # Returns nothing.
    def add(config)
      klass = Class.new self
      klass.instance_variable_set '@config', config

      if Brakeman.const_get klass.name
        raise DuplicateCheckError, "class named #{klass.name} already exists"
      end

      Brakeman.const_set(klass.name, klass)
      Brakeman::Checks.add klass
      Brakeman::WarningCodes::Codes[klass.warning_symbol] = klass.warning_code
    end

    # BaseCheck does parses name out of class name. We avoid that
    # here and set manually when creating the subclass.
    def inherited(subclass)
    end

    # Get the name from the configuration.
    #
    # Returns a String. Raises BadCheckAttribute if no name is configured.
    def name
      config[:name] ||
      raise(BadCheckAttribute, "custom check is missing a name")
    end

    # Get the description from the configuration.
    #
    # Returns a String. Raises BadCheckAttribute if no description is
    # configured.
    def description
      config[:description] ||
      raise(BadCheckAttribute, "custom check is missing a description")
    end

    # Get the warning symbol from the configuration.
    #
    # Returns a String. Raises BadCheckAttribute if no warning_symbol is
    # configured.
    def warning_symbol
      config[:warning_symbol] ||
      raise(BadCheckAttribute, "custom check is missing a warning_symbol")
    end

    # Get the configured warning code of attempt to derive a unique code from
    # the check configuration.
    #
    # Returns an Integer.
    def warning_code
      @warning_code ||= config[:warning_code] ||
                        Digest::MD5.hexdigest(config.to_s).to_i(16)
    end
  end

  def run_check
    Brakeman.debug "Finding calls for #{self.class.name}"

    # Parse out special targets.
    targets = config[:targets].dup
    if targets.delete ANY_MODEL_TARGET
      targets.concat tracker.models.keys
    end

    calls = tracker.find_calls :targets => targets,
                               :methods => methods

    Brakeman.debug "Processing results for #{self.class.name}"
    calls.each do |call|
      process_result call
    end
  end

  def process_result(result)
    return if duplicate? result
    add_result result

    target = result[:target]
    call   = result[:call]
    method = result[:method]

    # Get the relevant arguments from the call.
    args = call.args.values_at *arg_indices_for_method(method)
    args.uniq!

    message = "#{method} called on #{target}"

    args.find do |arg|
      next unless sexp? arg

      if match = has_immediate_user_input? arg
        message << " with immediate #{friendly_type_of match}"
        confidence = CONFIDENCE[:high]
      elsif match = has_immediate_model? arg
        match = Match.new(:model, match)
        message << " with #{friendly_type_of match}"
        confidence = CONFIDENCE[:med]
      elsif match = include_user_input? arg
        message << " with #{friendly_type_of match}"
        confidence = CONFIDENCE[:med]
      end
    end

    confidence ||= CONFIDENCE[:low]

    warn :result       => result,
         :warning_type => self.class.name,
         :warning_code => self.class.warning_symbol,
         :message      => message,
         :confidence   => confidence,
         :user_input   => match.try(:match)
  end

  # Get the Array of methods to look for from the check configuration.
  #
  # Returns a Array of Symbols.
  def methods
    @methods ||= begin
      case config[:methods]
      when Array
        config[:methods]
      when Hash
        config[:methods].keys
      else
        raise BadCheckAttribute
      end
    end
  end

  # Get the indices of the interesting arguments for a given method from the
  # check configuration.
  #
  # method - the Symbol name of the method.
  #
  # Returns an Array of values suitable for Array#values_at.
  def arg_indices_for_method(method)
    case config[:methods]
    when Array
      [0..-1]
    when Hash
      if config[:methods][method] == ALL_ARGUMENTS_TOKEN
        [0..-1]
      else
        Array[config[:methods][method]]
      end
    else
      raise BadCheckAttribute
    end
  end

  # Helper for accessing the class config.
  #
  # Returns a Hash.
  def config
    self.class.config
  end
end