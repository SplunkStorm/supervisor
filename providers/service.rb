#
# Author:: Noah Kantrowitz <noah@opscode.com>
# Cookbook Name:: supervisor
# Provider:: service
#
# Copyright:: 2011, Opscode, Inc <legal@opscode.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

action :enable do
  if current_resource.state != 'UNAVAILABLE'
    Chef::Log.debug "#{new_resource} is already enabled."
  else
    converge_by("Enabling #{ new_resource }") do
      enable_service
      new_resource.updated_by_last_action(true)
      Chef::Log.info "#{ new_resource } enabled."
    end
  end
end

action :disable do
  if current_resource.state == 'UNAVAILABLE'
    Chef::Log.debug "#{new_resource} is already disabled."
  else
    converge_by("Disabling #{new_resource}") do
      disable_service
      new_resource.updated_by_last_action(true)
      Chef::Log.info "#{ new_resource } disabled."
    end
  end
end

action :start do
  case current_resource.state
  when 'UNAVAILABLE'
    raise "Supervisor service #{new_resource.name} cannot be started because it does not exist"
  when 'RUNNING'
    Chef::Log.debug "#{ new_resource } is already started."
  when 'STARTING'
    Chef::Log.debug "#{ new_resource } is already starting."
    wait_til_state("RUNNING")
  else
    converge_by("Starting #{ new_resource }") do
      result = supervisorctl('start')
      if !result.match(/#{new_resource.name}(-\d+)?: started$/)
        raise "Supervisor service #{new_resource.name} was unable to be started: #{result}"
      end
      new_resource.updated_by_last_action(true)
      Chef::Log.info "#{ new_resource } started."
    end
  end
end

action :stop do
  case current_resource.state
  when 'UNAVAILABLE'
    raise "Supervisor service #{new_resource.name} cannot be stopped because it does not exist"
  when 'STOPPED'
    Chef::Log.debug "#{ new_resource } is already stopped."
  when 'STOPPING'
    Chef::Log.debug "#{ new_resource } is already stopping."
    wait_til_state("STOPPED")
  else
    converge_by("Stopping #{ new_resource }") do
      result = supervisorctl('stop')
      if !result.match(/#{new_resource.name}(-\d+)?: stopped$/)
        raise "Supervisor service #{new_resource.name} was unable to be stopped: #{result}"
      end
      Chef::Log.info "#{ new_resource } stopped."
      new_resource.updated_by_last_action(true)
    end
  end
end

action :restart do
  case current_resource.state
  when 'UNAVAILABLE'
    raise "Supervisor service #{new_resource.name} cannot be restarted because it does not exist"
  else
    converge_by("Restarting #{ new_resource }") do
      result = supervisorctl('restart')
      if !result.match(/^#{new_resource.name}(-\d+)?: started$/)
        raise "Supervisor service #{new_resource.name} was unable to be started: #{result}"
      end
      Chef::Log.info "Supervisor service #{new_resource.name} was restarted."
      new_resource.updated_by_last_action(true)
    end
  end
end

def enable_service
  e = execute "supervisorctl update" do
    action :nothing
    user "root"
  end

  t = template "#{node['supervisor']['dir']}/#{new_resource.service_name}.conf" do
    source "program.conf.erb"
    cookbook "supervisor"
    owner "root"
    group "root"
    mode "644"
    variables :prog => new_resource
    notifies :run, "execute[supervisorctl update]", :immediately
  end
  
  t.run_action(:create)
  if t.updated?
    e.run_action(:run)
  end
end

def disable_service
  execute "supervisorctl update" do
    action :nothing
    user "root"
  end

  file "#{node['supervisor']['dir']}/#{new_resource.service_name}.conf" do
    action :delete
    notifies :run, "execute[supervisorctl update]", :immediately
  end
end

def supervisorctl(action)
  cmd = "supervisorctl #{action} #{cmd_line_args}"
  result = Mixlib::ShellOut.new(cmd).run_command
  result.stdout.rstrip
end

def cmd_line_args
  name = new_resource.service_name
  if new_resource.numprocs > 1
    name += ':*'
  end
  name
end

def get_current_state(service_name)
  cmd = "supervisorctl status | grep '#{service_name}[: ]'"
  result = Mixlib::ShellOut.new(cmd).run_command
  stdout = result.stdout.strip

  if stdout.length == 0
    "UNAVAILABLE"
  else
    require 'set'
    states = Set.new
    valid_states = Set.new(['STOPPED', 'STOPPING', 'STARTING', 'BACKOFF', 'EXITED', 'FATAL', 'RUNNING'])

    if @new_resource.group_name
      re = Regexp.new(/(^#{@new_resource.group_name}:#{service_name}(:\S+)?\s*)([A-Z]+)/)
    else
      re = Regexp.new(/(^#{service_name}(:\S+)?\s*)([A-Z]+)/)
    end
    stdout.scan(re) {|match| states.add(match[2]) if valid_states.include?(match[2]) }

    if states.empty?
      raise "The supervisor service is not running as expected. " \
              "The command '#{cmd}' output:\n----\n#{stdout}\n----"
    end

    state = states.size() == 1 ? states.to_a[0] : 'MIXED'
    state
  end
end

def load_current_resource
  @current_resource = Chef::Resource::SupervisorService.new(@new_resource.name)
  @current_resource.state = get_current_state(@new_resource.name)
end

def wait_til_state(state,max_tries=20)
  service = new_resource.service_name

  max_tries.times do
    return if get_current_state(service) == state

    Chef::Log.debug("Waiting for service #{service} to be in state #{state}")
    sleep 1
  end
  
  raise "service #{service} not in state #{state} after #{max_tries} tries"

end
