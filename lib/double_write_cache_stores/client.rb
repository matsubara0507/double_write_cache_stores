module DoubleWriteCacheStores
  class Client # rubocop:disable Metrics/ClassLength
    attr_accessor :read_and_write_store, :write_only_store

    def initialize(read_and_write_store_servers, write_only_store_servers = nil)
      @read_and_write_store = read_and_write_store_servers
      if write_only_store_servers
        if read_and_write_store_servers.class != write_only_store_servers.class
          raise "different cache store instance. #{read_and_write_store_servers.class} != #{write_only_store_servers.class}"
        end
        @write_only_store = write_only_store_servers
      end
    end

    def [](key)
      get key
    end

    def get_cas(key)
      if @read_and_write_store.respond_to? :get_cas
        @read_and_write_store.get_cas key
      elsif @read_and_write_store.respond_to? :read_cas
        @read_and_write_store.read_cas key
      elsif @read_and_write_store.respond_to? :dalli
        @read_and_write_store.dalli.get_cas key
      end
    end

    def set_cas(key, value, cas = 0, options = nil)
      cas_unique = if @read_and_write_store.respond_to? :set_cas
                     @read_and_write_store.set_cas key, value, cas, options
                   elsif @read_and_write_store.respond_to? :read_cas
                     options ||= {}
                     options[:cas] = cas
                     @read_and_write_store.write_cas key, value, options
                   elsif @read_and_write_store.respond_to? :dalli
                     @read_and_write_store.dalli.set_cas key, value, cas, options
                   end

      if @write_only_store && cas_unique
        set_or_write_method_call @write_only_store, key, value, options
      end

      cas_unique
    end

    def delete(key)
      result = @read_and_write_store.delete key
      @write_only_store.delete key if @write_only_store
      result
    end

    def []=(key, value)
      set key, value
    end

    def touch(key, ttl = nil)
      result = if @read_and_write_store.respond_to? :touch
                 @read_and_write_store.touch key, ttl
               elsif @read_and_write_store.respond_to? :dalli
                 @read_and_write_store.dalli.touch key, ttl
               end

      if @write_only_store
        if @write_only_store.respond_to? :touch
          @write_only_store.touch key, ttl
        elsif @write_only_store.respond_to? :dalli
          @write_only_store.dalli.touch key, ttl
        end
      end

      result
    end

    def flush
      if flush_cache_store || flush_cache_store(:clear)
        true
      else
        false
      end
    end

    def fetch(name, options = {}, &_block)
      raise UnSupportException "Unsupported #fetch from client object." unless @read_and_write_store.respond_to?(:fetch)

      delete name if options[:force]

      if options[:race_condition_ttl]
        fetch_race_condition name, options { yield }
      else
        unless value = get_or_read_method_call(name)
          value = yield
          write_cache_store name, value, options
        end
        value
      end
    end

    def increment(key, amount = 1, options = {})
      increment_cache_store key, amount, options
    end
    alias_method :incr, :increment

    def decrement(key, amount = 1, options = {})
      decrement_cache_store key, amount, options
    end
    alias_method :decr, :decrement

    def write_cache_store(key, value, options = nil)
      set_or_write_method_call @read_and_write_store, key, value, options
      set_or_write_method_call @write_only_store, key, value, options if @write_only_store
    end
    alias_method :set, :write_cache_store
    alias_method :write, :write_cache_store

    def get_or_read_method_call(key)
      if @read_and_write_store.respond_to? :get
        @read_and_write_store.get key
      elsif @read_and_write_store.respond_to? :read
        @read_and_write_store.read key
      end
    end
    alias_method :get, :get_or_read_method_call
    alias_method :read, :get_or_read_method_call

    def get_multi_or_read_multi_method_call(*keys)
      if @read_and_write_store.respond_to? :get_multi
        @read_and_write_store.get_multi(*keys)
      elsif @read_and_write_store.respond_to? :read_multi
        @read_and_write_store.read_multi(*keys)
      else
        raise UnSupportException "Unsupported multi keys get or read from client object."
      end
    end
    alias_method :get_multi, :get_multi_or_read_multi_method_call
    alias_method :read_multi, :get_multi_or_read_multi_method_call

    private

      def fetch_race_condition(key, options, &_block)
        result = fetch_to_cache_store(@read_and_write_store, key, options) { yield }
        fetch_to_cache_store(@write_only_store, key, options) { result } if @write_only_store && @write_only_store.respond_to?(:fetch)
        result
      end

      def fetch_to_cache_store(cache_store, key, options, &_block)
        if cache_store.is_a? Dalli::Client
          ttl = options[:expires_in]
          cache_store.fetch key, ttl, options { yield }
        else
          cache_store.fetch key, options { yield }
        end
      end

      def set_or_write_method_call(cache_store, key, value, options)
        if cache_store.respond_to? :set
          ttl = options[:expires_in] if options
          cache_store.set key, value, ttl, options
        elsif cache_store.respond_to? :write
          cache_store.write key, value, options
        end
      end

      def increment_cache_store(key, amount, options)
        rw_store_value = incr_or_increment_method_call @read_and_write_store, key, amount, options
        return rw_store_value unless @write_only_store
        incr_or_increment_method_call @write_only_store, key, amount, options
      end

      def decrement_cache_store(key, amount, options)
        rw_store_value = decr_or_decrement_method_call @read_and_write_store, key, amount, options
        return rw_store_value unless @write_only_store
        decr_or_decrement_method_call @write_only_store, key, amount, options
      end

      def incr_or_increment_method_call(cache_store, key, amount, options)
        ttl = options[:expires_in] if options
        default = options.key?(:initial) ? options[:initial] : amount
        if cache_store.is_a? Dalli::Client
          cache_store.incr key, amount, ttl, default
        elsif cache_store.respond_to? :increment
          options[:initial] = amount unless options.key?(:initial)
          cache_store.increment key, amount, **options
        end
      end

      def decr_or_decrement_method_call(cache_store, key, amount, options)
        if cache_store.is_a?(Dalli::Client)
          ttl = options[:expires_in] if options
          default = options.key?(:initial) ? options[:initial] : 0
          cache_store.decr key, amount, ttl, default
        elsif cache_store.respond_to? :decrement
          options[:initial] = 0 unless options.key?(:initial)
          cache_store.decrement key, amount, **options
        end
      end

      def flush_cache_store(method = :flush)
        if @read_and_write_store.respond_to? method
          if @write_only_store && @write_only_store.respond_to?(method)
            @write_only_store.send method
          end
          @read_and_write_store.send method
        else
          false
        end
      end
  end
end
