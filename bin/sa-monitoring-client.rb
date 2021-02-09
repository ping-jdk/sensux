require 'rubygems'
require 'amqp'
require 'json'

config_file = if ENV['dev']
  File.dirname(__FILE__) + '/../config.json'
else
  '/etc/sa-monitoring/config.json'
end

config = JSON.parse(File.open(config_file, 'r').read)

AMQP.start(:host => config['rabbitmq_server']) do

  amq = MQ.new

  result = amq.fanout('results')

  config['client']['subscriptions'].each do |exchange|

    amq.queue(exchange).bind(amq.fanout(exchange)).subscribe do |check|

      execute_check = proc do
        output = IO.popen(config['checks'][check]['command']).gets
        {
          'output' => output,
          'status' => $?.to_i
        }
      end

      send_result = proc do |check_result|
        result.publish(check_result.to_json)
      end

      EM.defer(execute_check, send_result)
    end
  end
end
