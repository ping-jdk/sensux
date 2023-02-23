require File.join(File.dirname(__FILE__), 'config')
require 'em-hiredis'

module Sensu
  class Server
    attr_accessor :redis, :is_worker
    alias :redis_connection :redis

    def self.run(options={})
      EM.threadpool_size = 15
      EM.run do
        server = self.new(options)
        server.setup_logging
        server.setup_redis
        server.setup_amqp
        server.setup_keepalives
        server.setup_results
        unless server.is_worker
          server.setup_publisher
          server.setup_keepalive_monitor
        end
        server.monitor_queues

        Signal.trap('INT') do
          EM.stop
        end

        Signal.trap('TERM') do
          EM.stop
        end
      end
    end

    def initialize(options={})
      config = Sensu::Config.new(:config_file => options[:config_file])
      @settings = config.settings
      @is_worker = options[:worker]
    end

    def setup_logging
      EM.syslog_setup(@settings['syslog']['host'], @settings['syslog']['port'])
    end

    def setup_redis
      @redis = EM::Hiredis.connect('redis://' + @settings['redis']['host'] + ':' + @settings['redis']['port'].to_s)
    end

    def setup_amqp
      connection = AMQP.connect(symbolize_keys(@settings['rabbitmq']))
      @amq = MQ.new(connection)
    end

    def setup_keepalives
      @keepalive_queue = @amq.queue('keepalives')
      @keepalive_queue.subscribe do |keepalive_json|
        client = JSON.parse(keepalive_json)['name']
        @redis.set('client:' + client, keepalive_json).callback do
          @redis.sadd('clients', client)
        end
      end
    end

    def handle_event(event)
      handler = proc do
        output = ''
        IO.popen(@settings['handlers'][event['check']['handler']] + ' 2>&1', 'r+') do |io|
          io.write(event.to_json)
          io.close_write
          output = io.read
        end
        output
      end
      report = proc do |output|
        output.split(/\n+/).each do |line|
          EM.debug(line)
        end
      end
      EM.defer(handler, report)
    end

    def process_result(result)
      @redis.get('client:' + result['client']).callback do |client_json|
        unless client_json.nil?
          client = JSON.parse(client_json)
          check = result['check']
          if @settings['checks'][check['name']]
            check.merge!(@settings['checks'][check['name']])
          end
          check['handler'] ||= 'default'
          event = {'client' => client, 'check' => check, 'occurrences' => 1}
          if check['type'] == 'metric'
            handle_event(event)
          else
            history_key = 'history:' + client['name'] + ':' + check['name']
            @redis.rpush(history_key, check['status']).callback do
              @redis.lrange(history_key, -21, -1).callback do |history|
                total_state_change = 0
                unless history.count < 21
                  state_changes = 0
                  change_weight = 0.8
                  history.each do |status|
                    previous_status ||= status
                    unless status == previous_status
                      state_changes += change_weight
                    end
                    change_weight += 0.02
                    previous_status = status
                  end
                  total_state_change = (state_changes.fdiv(20) * 100).to_i
                  @redis.lpop(history_key)
                end
                high_flap_threshold = check['high_flap_threshold'] || 50
                low_flap_threshold = check['low_flap_threshold'] || 40
                @redis.hget('events:' + client['name'], check['name']).callback do |event_json|
                  previous_event = event_json ? JSON.parse(event_json) : false
                  flapping = previous_event ? previous_event['flapping'] : false
                  check['flapping'] = case
                  when total_state_change >= high_flap_threshold
                    true
                  when flapping && total_state_change <= low_flap_threshold
                    false
                  else
                    flapping
                  end
                  if previous_event && check['status'] == 0
                    unless check['flapping']
                      @redis.hdel('events:' + client['name'], check['name']).callback do
                        event['action'] = 'resolve'
                        handle_event(event)
                      end
                    else
                      @redis.hset('events:' + client['name'], check['name'], previous_event.merge({'flapping' => true}).to_json)
                    end
                  elsif check['status'] != 0
                    if previous_event && check['status'] == previous_event['status']
                      event['occurrences'] = previous_event['occurrences'] += 1
                    end
                    @redis.hset('events:' + client['name'], check['name'], {
                      'status' => check['status'],
                      'output' => check['output'],
                      'flapping' => check['flapping'],
                      'occurrences' => event['occurrences']
                    }.to_json).callback do
                      event['action'] = 'create'
                      handle_event(event)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    def setup_results
      @result_queue = @amq.queue('results')
      @result_queue.subscribe do |result_json|
        result = JSON.parse(result_json)
        process_result(result)
      end
    end

    def setup_publisher(options={})
      exchanges = Hash.new
      stagger = options[:test] ? 0 : 7
      @settings['checks'].each_with_index do |(name, details), index|
        EM.add_timer(stagger*index) do
          details['subscribers'].each do |exchange|
            if exchanges[exchange].nil?
              exchanges[exchange] = @amq.fanout(exchange)
            end
            interval = options[:test] ? 0.5 : details['interval']
            EM.add_periodic_timer(interval) do
              exchanges[exchange].publish({'name' => name, 'issued' => Time.now.to_i}.to_json)
              EM.debug('name="Published Check" event_id=server action="Published check ' + name + ' to the ' + exchange + ' exchange"')
            end
          end
        end
      end
    end

    def setup_keepalive_monitor
      EM.add_periodic_timer(30) do
        @redis.smembers('clients').callback do |clients|
          clients.each do |client_id|
            @redis.get('client:' + client_id).callback do |client_json|
              client = JSON.parse(client_json)
              time_since_last_check = Time.now.to_i - client['timestamp']
              result = {'client' => client['name'], 'check' => {'name' => 'keepalive', 'issued' => Time.now.to_i}}
              case
              when time_since_last_check >= 180
                result['check']['status'] = 2
                result['check']['output'] = 'No keep-alive sent from host in over 180 seconds'
                process_result(result)
              when time_since_last_check >= 120
                result['check']['status'] = 1
                result['check']['output'] = 'No keep-alive sent from host in over 120 seconds'
                process_result(result)
              else
                @redis.hexists('events:' + client_id, 'keepalive').callback do |exists|
                  if exists == 1
                    result['check']['status'] = 0
                    result['check']['output'] = 'Keep-alive sent from host'
                    process_result(result)
                  end
                end
              end
            end
          end
        end
      end
    end

    def monitor_queues
      EM.add_periodic_timer(5) do
        unless @keepalive_queue.subscribed?
          setup_keepalives
        end
        unless @result_queue.subscribed?
          setup_results
        end
      end
    end
  end
end
