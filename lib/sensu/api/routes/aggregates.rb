module Sensu
  module API
    module Routes
      module Aggregates
        AGGREGATES_URI = "/aggregates".freeze
        AGGREGATE_URI = /^\/aggregates\/([\w\.-]+)$/
        AGGREGATE_CLIENTS_URI = /^\/aggregates\/([\w\.-]+)\/clients$/
        AGGREGATE_CHECKS_URI = /^\/aggregates\/([\w\.-]+)\/checks$/
        AGGREGATE_RESULTS_SEVERITY_URI = /^\/aggregates\/([\w\.-]+)\/results\/([\w\.-]+)$/

        def get_aggregates
          @redis.smembers("aggregates") do |aggregates|
            aggregates.map! do |aggregate|
              {:name => aggregate}
            end
            @response_content = aggregates
            respond
          end
        end

        def get_aggregate
          aggregate = AGGREGATE_URI.match(@http_request_uri)[1]
          @redis.smembers("aggregates:#{aggregate}") do |aggregate_members|
            unless aggregate_members.empty?
              @response_content = {
                :clients => 0,
                :checks => 0,
                :results => {
                  :ok => 0,
                  :warning => 0,
                  :critical => 0,
                  :unknown => 0,
                  :total => 0,
                  :stale => 0
                }
              }
              clients = []
              checks = []
              results = []
              aggregate_members.each_with_index do |member, index|
                client_name, check_name = member.split(":")
                clients << client_name
                checks << check_name
                result_key = "result:#{client_name}:#{check_name}"
                @redis.get(result_key) do |result_json|
                  unless result_json.nil?
                    results << Sensu::JSON.load(result_json)
                  else
                    @redis.srem("aggregates:#{aggregate}", member)
                  end
                  if index == aggregate_members.length - 1
                    @response_content[:clients] = clients.uniq.length
                    @response_content[:checks] = checks.uniq.length
                    max_age = integer_parameter(@params[:max_age])
                    if max_age
                      result_count = results.length
                      timestamp = Time.now.to_i - max_age
                      results.reject! do |result|
                        result[:executed] < timestamp
                      end
                      @response_content[:results][:stale] = result_count - results.length
                    end
                    @response_content[:results][:total] = results.length
                    results.each do |result|
                      severity = (SEVERITIES[result[:status]] || "unknown")
                      @response_content[:results][severity.to_sym] += 1
                    end
                    respond
                  end
                end
              end
            else
              not_found!
            end
          end
        end

        def delete_aggregate
          aggregate = AGGREGATE_URI.match(@http_request_uri)[1]
          @redis.smembers("aggregates") do |aggregates|
            if aggregates.include?(aggregate)
              @redis.srem("aggregates", aggregate) do
                @redis.del("aggregates:#{aggregate}") do
                  no_content!
                end
              end
            else
              not_found!
            end
          end
        end

        def get_aggregate_clients
          aggregate = AGGREGATE_CLIENTS_URI.match(@http_request_uri)[1]
          @response_content = []
          @redis.smembers("aggregates:#{aggregate}") do |aggregate_members|
            unless aggregate_members.empty?
              clients = {}
              aggregate_members.each do |member|
                client_name, check_name = member.split(":")
                clients[client_name] ||= []
                clients[client_name] << check_name
              end
              clients.each do |client_name, checks|
                @response_content << {
                  :name => client_name,
                  :checks => checks
                }
              end
              respond
            else
              not_found!
            end
          end
        end

        def get_aggregate_checks
          aggregate = AGGREGATE_CHECKS_URI.match(@http_request_uri)[1]
          @response_content = []
          @redis.smembers("aggregates:#{aggregate}") do |aggregate_members|
            unless aggregate_members.empty?
              checks = {}
              aggregate_members.each do |member|
                client_name, check_name = member.split(":")
                checks[check_name] ||= []
                checks[check_name] << client_name
              end
              checks.each do |check_name, clients|
                @response_content << {
                  :name => check_name,
                  :clients => clients
                }
              end
              respond
            else
              not_found!
            end
          end
        end

        def get_aggregate_results_severity
          uri_match = AGGREGATE_RESULTS_SEVERITY_URI.match(@http_request_uri)
          aggregate = uri_match[1]
          severity = uri_match[2]
          @response_content = []
          if SEVERITIES.include?(severity)
            @redis.smembers("aggregates:#{aggregate}") do |aggregate_members|
              unless aggregate_members.empty?
                summaries = Hash.new
                max_age = integer_parameter(@params[:max_age])
                current_timestamp = Time.now.to_i
                aggregate_members.each_with_index do |member, index|
                  client_name, check_name = member.split(":")
                  result_key = "result:#{client_name}:#{check_name}"
                  @redis.get(result_key) do |result_json|
                    unless result_json.nil?
                      result = Sensu::JSON.load(result_json)
                      if SEVERITIES[result[:status]] == severity &&
                          (max_age.nil? || result[:executed] >= (current_timestamp - max_age))
                        summaries[check_name] ||= {}
                        summaries[check_name][result[:output]] ||= {:total => 0, :clients => []}
                        summaries[check_name][result[:output]][:total] += 1
                        summaries[check_name][result[:output]][:clients] << client_name
                      end
                    end
                    if index == aggregate_members.length - 1
                      summaries.each do |check_name, outputs|
                        summary = outputs.map do |output, output_summary|
                          {:output => output}.merge(output_summary)
                        end
                        @response_content << {
                          :check => check_name,
                          :summary => summary
                        }
                      end
                      respond
                    end
                  end
                end
              else
                not_found!
              end
            end
          else
            bad_request!
          end
        end
      end
    end
  end
end
