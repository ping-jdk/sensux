#
# Cookbook Name:: sa_monitoring
# Recipe:: api
#
# Copyright 2011, YOUR_COMPANY_NAME
#
# All rights reserved - Do Not Redistribute
#

include_recipe "sa_monitoring::default"

gem_package "thin"

template "/etc/init/sa-monitoring-api.conf" do
  source "upstart.erb"
  variables :service => "api"
  mode 0644
end

service "sa-monitoring-api" do
  provider Chef::Provider::Service::Upstart
  action [:enable, :start]
  subscribes :restart, resources(:file => "/etc/sa-monitoring/config.json"), :delayed
end
