#require 'fog/vcloud_director'

require 'pry-byebug'
require 'byebug'

#   fog:Vcair:<client id>
class Chef
  module Provisioning
    module FogDriver
      module Providers
        class Vcair < FogDriver::Driver
          Driver.register_provider_class('Vcair', FogDriver::Providers::Vcair)

          def creator
            Chef::Config[:knife][:vcair_username],
          end

          def compute
            # Vcair
            #  based on knife vcair add_api_endpoint()
            # FROM knife vcair plugin -- vcair_service.rb specific connection setup
            @compute ||= begin
                           Chef::Log.debug("vcair_username #{Chef::Config[:knife][:vcair_username]}")
                           Chef::Log.debug("vcair_org #{Chef::Config[:knife][:vcair_org]}")
                           Chef::Log.debug("vcair_api_host #{Chef::Config[:knife][:vcair_api_host]}")
                           #Chef::Log.debug("vcair_api_version #{Chef::Config[:knife][:vcair_api_version]}")
                           Chef::Log.debug("vcair_show_progress #{Chef::Config[:knife][:vcair_show_progress]}")

                           username = [
                             Chef::Config[:knife][:vcair_username],
                             Chef::Config[:knife][:vcair_org]
                           ].join('@')

                           @auth_params = {
                             :provider => 'vclouddirector', #TODO: see compute_options_for, and grab else where
                             :vcloud_director_username => username,
                             :vcloud_director_password => Chef::Config[:knife][:vcair_password],
                             :vcloud_director_host => Chef::Config[:knife][:vcair_api_host],
                             #:vcair_api_host => Chef::Config[:knife][:vcair_api_host],
                             :vcloud_director_api_version => Chef::Config[:knife][:vcair_api_version],
                             :vcloud_director_show_progress => false
                           }

                           Fog::Compute.new(@auth_params)
                         rescue Excon::Errors::Unauthorized => e
                           error_message = "Connection failure, please check your username and password."
                           Chef::Log.error(error_message)
                           #raise CloudExceptions::ServiceConnectionError, "#{e.message}. #{error_message}"
                           raise "#{e.message}. #{error_message}"
                         rescue Excon::Errors::SocketError => e
                           error_message = "Connection failure, please check your authentication URL."
                           Chef::Log.error(error_message)
                           raise "#{e.message}. #{error_message}"
                         end
          end


          def create_many_servers(num_servers, bootstrap_options, parallelizer)
            parallelizer.parallelize(1.upto(num_servers)) do |i|
              clean_bootstrap_options = Marshal.load(Marshal.dump(bootstrap_options)) # Prevent destructive operations on bootstrap_options.
              # Vcair
              # FROM knife vcair plugin --  specific server create
              vm=nil
              begin
                # ORIGINAL driver.rb:
                #    server = compute.servers.create(bootstrap_options[:server_def])

                #Chef::Config[:knife][:ssh_password] = ENV['VCAIR_SSH_PASSWORD']
                #Chef::Config[:ssh_password] = ENV['VCAIR_SSH_PASSWORD']
                #Chef::Config[:password] = ENV['VCAIR_SSH_PASSWORD']
                #Chef::Config[:knife][:chef_node_name] = 'centosdemo1'
                #Chef::Config[:knife][:chef_node_name] = machine_spec.name
                #Chef::Config[:knife][:chef_node_name] = 'linuxdemoapp1'
                #Chef::Config[:knife][:chef_node_name] = bootstrap_options[:name]

                # Vcair
                #  From vcair_server_create.rb
                i = instantiate(clean_bootstrap_options)

                # vapp(), vm() inlined
                vapp = vdc.vapps.get_by_name(bootstrap_options[:name])
                vm = vapp.vms.find {|v| v.vapp_name == bootstrap_options[:name]}

                c = update_customization(clean_bootstrap_options, vm)

                # TODO: grab cpu from bootstrap
                if bootstrap_options[:cpus]
                  vm.cpu = bootstrap_options[:cpus]
                end
                if bootstrap_options[:memory]
                  vm.memory = bootstrap_options[:memory]
                end
                n = update_network(bootstrap_options, vapp, vm)

                # NOTE: called automatically from in start_server
                #v= vm.power_on

              rescue Excon::Errors::BadRequest => e
                response = Chef::JSONCompat.from_json(e.response.body)
                if response['badRequest']['code'] == 400
                  message = "Bad request (400): #{response['badRequest']['message']}"
                  Chef::Log.error(message)
                else
                  message = "Unknown server error (#{response['badRequest']['code']}): #{response['badRequest']['message']}"
                  Chef::Log.error(message)
                end
                raise message
              rescue Fog::Errors::Error => e
                raise e.message
              end

              #vapps.get_by_name(Chef::Config[:knife][:chef_node_name])

              # vms = []
              # vdc.vapps.all.each do |vapp|
              #   vms << vapp.vms.all
              # end
              # vms = vms.flatten

              #vms = vapp.vms
              ##server = vms.select{|v| v.vapp_name == machine_spec.name }.first
              ##server = vms.find{|v| v.vapp_name == Chef::Config[:knife][:chef_node_name]}
              #server = vms.find{|v| v.vapp_name == bootstrap_options[:name]}
              ##server = vms.first

              #bootstrap_options[:server_create_timeout]=60
              # bootstrap_options[:server_create_timeout]=600
              # bootstrap_options[:create_timeout]=600
              # bootstrap_options[:start_timeout]=600
              # machine_options[:server_create_timeout]=600
              # machine_options[:start_timeout]=600
              # machine_options[:create_timeout]=600
              #
              puts "Waiting for server [wait time = #{bootstrap_options[:create_timeout]}]"

              # wait for it to be ready to do stuff
              vm.wait_for(Integer(bootstrap_options[:create_timeout])) { puts "."; ready? }

              #puts("\n")
              #server

              yield vm if block_given?
              vm

            end.to_a
          end


          def start_server(action_handler, machine_spec, server)

            # If it is stopping, wait for it to get out of "stopping" transition state before starting
            # Vcair:
            if server.status == 'stopping'
              action_handler.report_progress "wait for #{machine_spec.name} (#{server.id} on #{driver_url}) to finish stopping ..."
              # Vcair
              # NOTE: Vcair fog does not get server.status via http every time
              server.wait_for { server.reload ; server.status != 'stopping' }
              action_handler.report_progress "#{machine_spec.name} is now stopped"
            end

            # NOTE: Vcair fog does not get server.status via http every time
            server.reload

            # Vcair:
            if server.status == 'off' or server.status != 'on'
              action_handler.perform_action "start machine #{machine_spec.name} (#{server.id} on #{driver_url})" do
                # Vcair
                server.power_on
                machine_spec.location['started_at'] = Time.now.to_i
              end
              machine_spec.save(action_handler)
            end
          end


          def server_for(machine_spec)
            if machine_spec.location
              vapp = vdc.vapps.get_by_name(machine_spec.name)

              server = unless vapp.nil?
                         unless vapp.vms.first.nil?
                           vapp.vms.find{|vm| vm.id == machine_spec.location['server_id'] }
                         end
                       end
            else
              nil
            end
          end

          def servers_for(machine_specs)
            result = {}
            machine_specs.each do |machine_spec|
              server_for(machine_spec)
            end
            result
          end

          def ssh_options_for(machine_spec, machine_options, server)
            # Vcair
            result = case provider
                     when 'vclouddirector'
                       # machine_options = { start_timeout: 600, create_timeout: 600 }.merge(machine_options || {})
                       # machine_options[:bootstrap_options] = { start_timeout: 600, create_timeout: 600 }.merge(machine_options[:bootstrap_options] || {})
                       result = { 
                         auth_methods: [ 'password' ],
                         timeout: (machine_options[:ssh_timeout] || 600),
                         password: machine_options[:ssh_password]
                       }.merge(machine_options[:ssh_options] || {})
                     else
                       super(machine_spec, machine_options, server)
                     end
            result
          end

          def create_ssh_transport(machine_spec, machine_options, server)
            ssh_options = ssh_options_for(machine_spec, machine_options, server)
            username = machine_spec.location['ssh_username'] || default_ssh_username
            options = {}
            if machine_spec.location[:sudo] || (!machine_spec.location.has_key?(:sudo) && username != 'root')
              options[:prefix] = 'sudo '
            end

            remote_host = nil
            # Vcair networking is funky
            if provider == 'vclouddirector' #driver_url.match(/fog:Vcair/)
              #if machine_options[:use_private_ip_for_ssh] # Vcair probably needs private ip for now
              if server.ip_address
                remote_host = server.ip_address
              else
                raise "Server #{server.id} has no private or public IP address!"
              end
            end

            #Enable pty by default
            options[:ssh_pty_enable] = true
            options[:ssh_gateway] = machine_spec.location['ssh_gateway'] if machine_spec.location.has_key?('ssh_gateway')

            Transport::SSH.new(remote_host, username, ssh_options, options, config)
          end

          def ready_machine(action_handler, machine_spec, machine_options)
            server = server_for(machine_spec)
            if server.nil?
              raise "Machine #{machine_spec.name} does not have a server associated with it, or server does not exist."
            end

            # Start the server if needed, and wait for it to start
            start_server(action_handler, machine_spec, server)
            wait_until_ready(action_handler, machine_spec, machine_options, server)

            # Attach/detach floating IPs if necessary
            # Vcair is funky for network.  vm has to be powered off or you get this error:
            #    Primary NIC cannot be changed when the VM is not in Powered-off state
            # See code in update_network()
            #DISABLED: converge_floating_ips(action_handler, machine_spec, machine_options, server)

            begin
              wait_for_transport(action_handler, machine_spec, machine_options, server)
            rescue Fog::Errors::TimeoutError
              # Only ever reboot once, and only if it's been less than 10 minutes since we stopped waiting
              if machine_spec.location['started_at'] || remaining_wait_time(machine_spec, machine_options) < -(10*60)
                raise
              else
                # Sometimes (on EC2) the machine comes up but gets stuck or has
                # some other problem.  If this is the case, we restart the server
                # to unstick it.  Reboot covers a multitude of sins.
                Chef::Log.warn "Machine #{machine_spec.name} (#{server.id} on #{driver_url}) was started but SSH did not come up.  Rebooting machine in an attempt to unstick it ..."
                restart_server(action_handler, machine_spec, server)
                wait_until_ready(action_handler, machine_spec, machine_options, server)
                wait_for_transport(action_handler, machine_spec, machine_options, server)
              end
            end

            machine_for(machine_spec, machine_options, server)
          end

          def org
            @org ||= compute.organizations.get_by_name(Chef::Config[:knife][:vcair_org])
          end

          def vdc
            if Chef::Config[:knife][:vcair_vdc]
              @vdc ||= org.vdcs.get_by_name(Chef::Config[:knife][:vcair_vdc])
            else
              @vdc ||= org.vdcs.first
            end
          end

          def net
            if Chef::Config[:knife][:vcair_net]
              @net ||= org.networks.get_by_name(Chef::Config[:knife][:vcair_net])
            else
              # Grab first non-isolated (bridged, natRouted) network
              @net ||= org.networks.find { |n| n if !n.fence_mode.match("isolated") }
            end
          end

          def template(bootstrap_options)
            # TODO: find by catalog item ID and/or NAME
            # TODO: add option to search just public and/or private catalogs

            #Chef::Config[:knife][:image] = 'CentOS64-64BIT'
            #TODO: maybe make a hash for caching
            org.catalogs.map do |cat|
              #cat.catalog_items.get_by_name(config_value(:image))
              cat.catalog_items.get_by_name(bootstrap_options[:image_name])
            end.compact.first
          end

          # def vapp
          #   #@vapp ||= vdc.vapps.get_by_name(config_value(:chef_node_name))
          #   vdc.vapps.get_by_name(config_value(:chef_node_name))
          # end

          # def vm
          #   @vm ||= vapp.vms.find {|v| v.vapp_name == config_value(:chef_node_name)}
          # end

          # def network_config
          #   @network_config ||= vapp.network_config.find do |n|
          #     n if n[:networkName].match(net.name)
          #   end
          # end

          # def config_value(key)
          #   key = key.to_sym
          #   Chef::Config[:knife][key] || config[key]
          # end

          def instantiate(bootstrap_options)
            begin
              #node_name = config_value(:chef_node_name)
              node_name = bootstrap_options[:name]
              template(bootstrap_options).instantiate(
                node_name,
                vdc_id: vdc.id,
                network_id: net.id,
                description: "id:#{node_name}")
              #rescue CloudExceptions::ServerCreateError => e
            rescue => e
              raise e
            end
          end

          def update_customization(bootstrap_options, server)
            ## Initialization before first power on.
            c=server.customization

            if bootstrap_options[:customization_script]
              c.script = open(bootstrap_options[:customization_script]).read
            end


            # TODO: check machine type and pick accordingly for Chef provisioning
            # password = case config_value(:bootstrap_protocol)
            #            when 'winrm'
            #              config_value(:winrm_password)
            #            when 'ssh'
            #              config_value(:ssh_password)
            #            end

            password = bootstrap_options[:ssh_password]
            if password
              c.admin_password =  password 
              c.admin_password_auto = false
              c.reset_password_required = false
            else
              # Password will be autogenerated
              c.admin_password_auto=true
              # API will force password resets when auto is enabled
              c.reset_password_required = true
            end

            # TODO: Add support for admin_auto_logon to fog
            # c.admin_auto_logon_count = 100
            # c.admin_auto_logon_enabled = true

            # DNS and Windows want AlphaNumeric and dashes for hostnames
            # Windows can only handle 15 character hostnames
            # TODO: only change name for Windows!
            #c.computer_name = config_value(:chef_node_name).gsub(/\W/,"-").slice(0..14)
            c.computer_name = bootstrap_options[:name].gsub(/\W/,"-").slice(0..14)
            c.enabled = true
            c.save
          end

          ## Vcair
          ## TODO: make work with floating_ip junk currently used
          ## NOTE: current vcair networking changes require VM to be powered off
          def update_network(bootstrap_options, vapp, vm)
            ## TODO: allow user to specify network to connect to (see above net used)
            # Define network connection for vm based on existing routed network

            # Vcair inlining vapp() and vm()
            #vapp = vdc.vapps.get_by_name(bootstrap_options[:name])
            #vm = vapp.vms.find {|v| v.vapp_name == bootstrap_options[:name]}
            nc = vapp.network_config.find { |n| n if n[:networkName].match(net.name) }
            networks_config = [nc]
            section = {PrimaryNetworkConnectionIndex: 0}
            section[:NetworkConnection] = networks_config.compact.each_with_index.map do |network, i|
              connection = {
                network: network[:networkName],
                needsCustomization: true,
                NetworkConnectionIndex: i,
                IsConnected: true
              }
              ip_address      = network[:ip_address]
              ## TODO: support config options for allocation mode
              #allocation_mode = network[:allocation_mode]
              #allocation_mode = 'manual' if ip_address
              #allocation_mode = 'dhcp' unless %w{dhcp manual pool}.include?(allocation_mode)
              #allocation_mode = 'POOL'
              #connection[:Dns1] = dns1 if dns1
              allocation_mode = 'pool'
              connection[:IpAddressAllocationMode] = allocation_mode.upcase
              connection[:IpAddress] = ip_address if ip_address
              connection
            end

            ## attach the network to the vm
            nc_task = compute.put_network_connection_system_section_vapp(
              vm.id,section).body
              compute.process_task(nc_task)
          end

          ##### END FROM knife Vcair

          def bootstrap_options_for(action_handler, machine_spec, machine_options)
            bootstrap_options = symbolize_keys(machine_options[:bootstrap_options] || {})
            # if bootstrap_options[:key_path]
            #   bootstrap_options[:key_name] ||= File.basename(bootstrap_options[:key_path])
            #   # Verify that the provided key name and path are in line (or create the key pair if not!)
            #   driver = self
            #   Provisioning.inline_resource(action_handler) do
            #     fog_key_pair bootstrap_options[:key_name] do
            #       private_key_path bootstrap_options[:key_path]
            #       driver driver
            #     end
            #   end
            # else
            #   bootstrap_options[:key_name] = overwrite_default_key_willy_nilly(action_handler, machine_spec)
            # end
            #
            bootstrap_options[:tags]  = default_tags(machine_spec, bootstrap_options[:tags] || {})
            bootstrap_options[:name] ||= machine_spec.name

            ## NOTE: these are displayed on the screen in GREEN
            #bootstrap_options[:server_create_timeout]=600
            # bootstrap_options[:create_timeout]=600
            # bootstrap_options[:start_timeout]=600
            # bootstrap_options[:ssh_options] = {} if bootstrap_options[:ssh_options].nil?
            # bootstrap_options[:ssh_options]={timeout: 600}.merge(bootstrap_options[:ssh_options] || {})

            # if machine_options[:vcair_options]
            #   bootstrap_options[:ssh_options][:password] = machine_options[:vcair_options][:ssh_password] if machine_options[:vcair_options][:ssh_password]
            #   # bootstrap_options[:ssh_options][:use_private_ip_for_ssh] = machine_options[:vcair_options][:use_private_ip_for_ssh] if machine_options[:vcair_options][:use_private_ip_for_ssh]
            #   # bootstrap_options[:ssh_options][:auth_methods] = machine_options[:vcair_options][:auth_methods] if machine_options[:vcair_options][:auth_methods]
            #   bootstrap_options[:image_name] = machine_options[:vcair_options][:bootstrap_options][:image_name]
            #   bootstrap_options[:memory] = machine_options[:vcair_options][:bootstrap_options][:memory]
            #   bootstrap_options[:cpus] = machine_options[:vcair_options][:bootstrap_options][:cpus]
            #   bootstrap_options[:net] = machine_options[:vcair_options][:bootstrap_options][:net]
            #   bootstrap_options[:customization_script] = machine_options[:vcair_options][:bootstrap_options][:customization_script]
            # end


            # if !bootstrap_options[:image_id]
            #   if !bootstrap_options[:image_distribution] && !bootstrap_options[:image_name]
            #     bootstrap_options[:image_distribution] = 'CentOS'
            #     bootstrap_options[:image_name] = '6.5 x64'
            #   end
            #   distributions = compute.images.select { |image| image.distribution == bootstrap_options[:image_distribution] }
            #   if distributions.empty?
            #     raise "No images on DigitalOcean with distribution #{bootstrap_options[:image_distribution].inspect}"
            #   end
            #   images = distributions.select { |image| image.name == bootstrap_options[:image_name] } if bootstrap_options[:image_name]
            #   if images.empty?
            #     raise "No images on DigitalOcean with distribution #{bootstrap_options[:image_distribution].inspect} and name #{bootstrap_options[:image_name].inspect}"
            #   end
            #   bootstrap_options[:image_id] = images.first.id
            # end
            # if !bootstrap_options[:flavor_id]
            #   bootstrap_options[:flavor_name] ||= '512MB'
            #   flavors = compute.flavors.select do |f|
            #     f.name == bootstrap_options[:flavor_name]
            #   end
            #   if flavors.empty?
            #     raise "Could not find flavor named '#{bootstrap_options[:flavor_name]}' on #{driver_url}"
            #   end
            #   bootstrap_options[:flavor_id] = flavors.first.id
            # end
            # if !bootstrap_options[:region_id]
            #   bootstrap_options[:region_name] ||= 'San Francisco 1'
            #   regions = compute.regions.select { |region| region.name == bootstrap_options[:region_name] }
            #   if regions.empty?
            #     raise "Could not find region named '#{bootstrap_options[:region_name]}' on #{driver_url}"
            #   end
            #   bootstrap_options[:region_id] = regions.first.id
            # end
            # keys = compute.ssh_keys.select { |k| k.name == bootstrap_options[:key_name] }
            # if keys.empty?
            #   raise "Could not find key named '#{bootstrap_options[:key_name]}' on #{driver_url}"
            # end
            # found_key = keys.first
            # bootstrap_options[:ssh_key_ids] ||= [ found_key.id ]
            #
            # # You don't get to specify name yourself
            #bootstrap_options[:name] = machine_spec.name

            binding.pry
            bootstrap_options
          end

          def destroy_machine(action_handler, machine_spec, machine_options)
            server = server_for(machine_spec)
            if server && server.status != 'archive' # TODO: does Vcair do archive?
              action_handler.perform_action "destroy machine #{machine_spec.name} (#{machine_spec.location['server_id']} at #{driver_url})" do
                #NOTE: currently doing 1 vm for 1 vapp
                vapp = vdc.vapps.get_by_name(machine_spec.name)
                if vapp
                  vapp.power_off
                  vapp.undeploy
                  vapp.destroy
                else
                  Chef::Log.warn "No VApp named '#{server_name}' was found."
                end
              end
            end
            machine_spec.location = nil
            strategy = convergence_strategy_for(machine_spec, machine_options)
            strategy.cleanup_convergence(action_handler, machine_spec)
          end

          def self.compute_options_for(provider, id, config)
            new_compute_options = {}
            new_compute_options[:provider] = 'vclouddirector'
            new_config = { :driver_options => { :compute_options => new_compute_options }}
            new_defaults = {
              :driver_options  => { :compute_options => {} },
              :machine_options => { :bootstrap_options => {}, :ssh_options => {} }
            }
            result = Cheffish::MergedConfig.new(new_config, config, new_defaults)

            #new_compute_options[:digitalocean_client_id] = id if (id && id != '')
            #[result, new_compute_options[:digitalocean_client_id]]
            [result, id]
          end
        end
      end
    end
  end
end
