require 'set'

#Stores call sites to look up later.
class Brakeman::CallIndex

  #Initialize index with calls from FindAllCalls
  def initialize calls
    @calls_by_method = Hash.new
    @calls_by_target = Hash.new

    index_calls calls
  end

  #Find calls matching specified option hash.
  #
  #Options:
  #
  #  * :target - symbol, array of symbols, or regular expression to match target(s)
  #  * :method - symbol, array of symbols, or regular expression to match method(s)
  #  * :chained - boolean, whether or not to match against a whole method chain (false by default)
  #  * :nested - boolean, whether or not to match against a method call that is a target itself (false by default)
  def find_calls options
    target = options[:target] || options[:targets]
    method = options[:method] || options[:methods]
    nested = options[:nested]

    if options[:chained]
      return find_chain options
    #Find by narrowest category
    elsif target and method and target.is_a? Array and method.is_a? Array
      if target.length > method.length
        calls = filter_by_target calls_by_methods(method), target
      else
        calls = calls_by_targets(target)
        calls = filter_by_method calls, method
      end

    #Find by target, then by methods, if provided
    elsif target
      calls = calls_by_target target

      if calls and method
        calls = filter_by_method calls, method
      end

    #Find calls with no explicit target
    #with either :target => nil or :target => false
    elsif options.key? :target and not target and method
      calls = calls_by_method method
      calls = filter_by_target calls, nil

    #Find calls by method
    elsif method
      calls = calls_by_method method
    else
      notify "Invalid arguments to CallCache#find_calls: #{options.inspect}"
    end

    return [] if calls.nil?

    #Remove calls that are actually targets of other calls
    #Unless those are explicitly desired
    calls = filter_nested calls unless nested

    calls
  end

  def remove_template_indexes template_name = nil
    @calls_by_method.each do |name, calls|
      calls.delete_if do |call|
        from_template call, template_name
      end
    end

    @calls_by_target.each do |name, calls|
      calls.delete_if do |call|
        from_template call, template_name
      end
    end
  end

  def remove_indexes_by_class classes
    @calls_by_method.each do |name, calls|
      calls.delete_if do |call|
        call[:location][:type] == :class and classes.include? call[:location][:class]
      end
    end

    @calls_by_target.each do |name, calls|
      calls.delete_if do |call|
        call[:location][:type] == :class and classes.include? call[:location][:class]
      end
    end
  end

  def index_calls calls
    calls.each do |call|
      @calls_by_method[call[:method]] ||= []
      @calls_by_method[call[:method]] << call

      unless call[:target].is_a? Sexp
        @calls_by_target[call[:target]] ||= []
        @calls_by_target[call[:target]] << call
      end
    end
  end

  private

  def find_chain options
    target = options[:target] || options[:targets]
    method = options[:method] || options[:methods]

    calls = calls_by_method method
    
    return [] if calls.nil?

    calls = filter_by_chain calls, target
  end

  def calls_by_target target
    if target.is_a? Array
      calls_by_targets target
    else
      @calls_by_target[target]
    end
  end

  def calls_by_targets targets
    calls = []

    targets.each do |target|
      calls.concat @calls_by_target[target] if @calls_by_target.key? target
    end

    calls
  end

  def calls_by_method method
    if method.is_a? Array
      calls_by_methods method
    else
      @calls_by_method[method.to_sym] || []
    end
  end

  def calls_by_methods methods
    methods = methods.map { |m| m.to_sym }
    calls = []

    methods.each do |method|
      calls.concat @calls_by_method[method] if @calls_by_method.key? method
    end

    calls
  end

  def calls_with_no_target
    @calls_by_target[nil] || []
  end

  def filter calls, key, value
    if value.is_a? Array
      values = Set.new value

      calls.select do |call|
        values.include? call[key]
      end
    elsif value.is_a? Regexp
      calls.select do |call|
        call[key].to_s.match value
      end
    else
      calls.select do |call|
        call[key] == value
      end
    end
  end

  def filter_by_method calls, method
    filter calls, :method, method
  end

  def filter_by_target calls, target
    filter calls, :target, target
  end

  def filter_nested calls
    filter calls, :nested, false
  end

  def filter_by_chain calls, target
    case target
    when Array
      target_types = {:chain => Set.new, :nochain => Set.new}
      target.each do |t|
        type = chain_target?(t) ? :chain : :nochain
        target_types[type].add t
      end

      calls.select do |call|
        target_types[:nochain].include?(call[:chain].first) ||
        target_types[:chain].include?(target_chain(call[:chain]))
      end
    when Regexp
      calls.select do |call|
        call[:chain].first.to_s.match target
      end
    when String, Symbol
      if chain_target?(target)
        target = target.to_s
        calls.select do |call|
          target == target_chain(call[:chain])
        end
      else
        calls.select do |call|
          call[:chain].first == target
        end        
      end
    else
      calls.select do |call|
        call[:chain].first == target
      end
    end
  end

  # Is this target query a chain itself?
  # Eg. "User.connection" or "connection"
  #
  # target - the target String/Regex to check.
  #
  # Returns truthy if the target contains a '.' or doesn't look like a
  # class/module, falsey otherwise.
  def chain_target?(target)
    (target.is_a?(String) || target.is_a?(Symbol)) &&
    (target['.'] || !('A'..'Z').include?(target[0]))
  end

  # Get the string target chain from a chain.
  #
  # Eg. [:Foo, :bar, :baz] => "Foo.bar"
  # Eg. [:bar, :baz]       => "bar"
  #
  # Calling `self.something` within an instance method results in a chain
  # like [:Foo, :something] and calling `self.class.something` results in
  # [:Foo, :class, :something]. YMMV
  #
  # chain - the chain Array to stringify.
  #
  # Returns a String.
  def target_chain(chain)
    chain[0...-1].compact.join('.')
  end

  def from_template call, template_name
    return false unless call[:location][:type] == :template
    return true if template_name.nil?
    call[:location][:template] == template_name
  end
end
