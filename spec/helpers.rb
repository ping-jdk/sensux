require 'rspec'

module Helpers
  def setup_options
    @options = {
      :config_file => File.join(File.dirname(__FILE__), 'config.json'),
      :config_dir => File.join(File.dirname(__FILE__), 'conf.d'),
      :extension_dir => File.join(File.dirname(__FILE__), 'extensions'),
      :log_level => :fatal
    }
  end

  def options
    @options ? @options : setup_options
  end

  def setup_redis
    @redis = EM::Protocols::Redis.connect
    @redis
  end

  def redis
    @redis ? @redis : setup_redis
  end

  def setup_amq
    rabbitmq = AMQP.connect
    @amq = AMQP::Channel.new(rabbitmq)
    @amq
  end

  def amq
    @amq ? @amq : setup_amq
  end

  def timer(delay, &block)
    periodic_timer = EM::PeriodicTimer.new(delay) do
      block.call
      periodic_timer.cancel
    end
  end

  def async_wrapper(&block)
    EM::run do
      timer(10) do
        raise 'test timed out'
      end
      block.call
    end
  end

  def async_done
    EM::stop_event_loop
  end

  def epoch
    Time.now.to_i
  end

  def client_template
    {
      :name => 'i-424242',
      :address => '127.0.0.1',
      :subscriptions => [
        'test'
      ]
    }
  end

  def event_template
    {
      :client => client_template,
      :check => {
        :name => 'foobar',
        :command => 'echo -n WARNING && exit 1',
        :issued => epoch,
        :output => 'WARNING',
        :status => 1,
        :history => [1]
      },
      :occurrences => 1,
      :action => :create
    }
  end

  def result_template
    {
      :client => 'i-424242',
      :check => {
        :name => 'foobar',
        :command => 'echo -n WARNING && exit 1',
        :issued => epoch,
        :output => 'WARNING',
        :status => 1
      }
    }
  end

  class TestServer < EM::Connection
    include RSpec::Matchers

    attr_accessor :expected

    def receive_data(data)
      data.should eq(expected)
      EM::stop_event_loop
    end
  end
end
