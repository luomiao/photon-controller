# Copyright 2015 VMware, Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed
# under the License is distributed on an "AS IS" BASIS, without warranties or
# conditions of any kind, EITHER EXPRESS OR IMPLIED. See the License for the
# specific language governing permissions and limitations under the License.

require "net/ssh"
require "spec_helper"
require "json"
require "test_helpers"

describe "Kubernetes photon cloud provider tests", cluster: true do

=begin
  before(:all) do
    @seeder = EsxCloud::SystemSeeder.instance
    @cleaner = EsxCloud::SystemCleaner.new(client)

    @deployment = @seeder.deployment!
    @kubernetes_image = EsxCloud::ClusterHelper.upload_kubernetes_image(client)
    EsxCloud::ClusterHelper.enable_cluster_type(client, @deployment, @kubernetes_image, "KUBERNETES")
		EsxCloud::ClusterHelper.generate_temporary_ssh_key
  end
=end

=begin
  after(:all) do
    puts "Starting to clean up Kubernetes Cluster lifecycle tests Env"
    EsxCloud::ClusterHelper.disable_cluster_type(client, @deployment, "KUBERNETES")
    @cleaner.delete_image(@kubernetes_image)
    EsxCloud::ClusterHelper.remove_temporary_ssh_key
  end
=end

  it 'should test Photon Controller cloud provider with a Kubernetes cluster' do
    fail("API_ADDRESS is not defined") unless ENV["API_ADDRESS"]
    fail("KUBERNETES_MASTER_IP is not defined") unless ENV["KUBERNETES_MASTER_IP"]
    fail("KUBERNETES_WORKER1_IP is not defined") unless ENV["KUBERNETES_WORKER1_IP"]
    fail("KUBERNETES_PDID1 is not defined") unless ENV["KUBERNETES_PDID1"]
    fail("KUBERNETES_PDID2 is not defined") unless ENV["KUBERNETES_PDID2"]
    fail("KUBERNETES_SC_FLAVOR is not defined") unless ENV["KUBERNETES_SC_FLAVOR"]

=begin
    puts "Starting to create a Kubernetes cluster"
    begin

      # Validate that the deployment API shows the cluster configurations.
      # We check both the "all deployments" and "deployment by ID" because there
      # was a bug in which they were returning different data
      deployment = client.find_all_api_deployments.items[0]
      expect(deployment.cluster_configurations.size).to eq 1
      expect(deployment.cluster_configurations[0].type).to eq "KUBERNETES"

      deployment = client.find_deployment_by_id(deployment.id)
      expect(deployment.cluster_configurations.size).to eq 1
      expect(deployment.cluster_configurations[0].type).to eq "KUBERNETES"

      project = @seeder.project!
      props = EsxCloud::ClusterHelper.construct_kube_properties(ENV["KUBERNETES_MASTER_IP"],ENV["KUBERNETES_ETCD_1_IP"])
      expected_etcd_count = 1
      if ENV["KUBERNETES_ETCD_2_IP"] != nil and ENV["KUBERNETES_ETCD_2_IP"] != ""
        props["etcd_ip2"] = ENV["KUBERNETES_ETCD_2_IP"]
        expected_etcd_count += 1
        if ENV["KUBERNETES_ETCD_3_IP"] != nil and ENV["KUBERNETES_ETCD_3_IP"] != ""
          props["etcd_ip3"] = ENV["KUBERNETES_ETCD_3_IP"]
          expected_etcd_count += 1
        end
      end
      puts "Creating Kubernetes cluster"
      cluster = project.create_cluster(
          name: random_name("kubernetes-"),
          type: "KUBERNETES",
          vm_flavor: @seeder.vm_flavor!.name,
          disk_flavor: @seeder.ephemeral_disk_flavor!.name,
          network_id: @seeder.network!.id,
          worker_count: 1,
          batch_size: nil,
          extended_properties: props
      )

      validate_kube_cluster_info(cluster, 1, @seeder.vm_flavor!.name)
      validate_kube_api_responding(ENV["KUBERNETES_MASTER_IP"], 2)

      EsxCloud::ClusterHelper.validate_ssh(ENV["KUBERNETES_MASTER_IP"])

      N_WORKERS = (ENV["N_SLAVES"] || 2).to_i

      resize_cluster(cluster, N_WORKERS, expected_etcd_count)

      puts "Test that cluster background maintenance will restore deleted VMs"
      validate_trigger_maintenance(ENV["KUBERNETES_MASTER_IP"], N_WORKERS, cluster)

    end
=end

    puts "Verify K8S API server and SSH"
    validate_kube_api_responding(ENV["KUBERNETES_MASTER_IP"], 2)
    EsxCloud::ClusterHelper.validate_ssh(ENV["KUBERNETES_MASTER_IP"])

    puts "Copying priv key (for kube nodes) test_rsa from local machine to management vm"
    copy_test_rsa_cmd = "sshpass -p \"vmware\" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/test_rsa esxcloud@#{ENV['API_ADDRESS']}:/tmp/"
    puts copy_test_rsa_cmd
    `#{copy_test_rsa_cmd}`

    populate_yaml_files()

    server = ENV['API_ADDRESS']
    user_name = "esxcloud"
    password = "vmware"
    Net::SSH.start(server, user_name, {password: password, user_known_hosts_file: "/dev/null"}) do |ssh|
	    copy_over_the_kubectl_from_master_node_to_devbox(ssh)
    end

		Net::SSH.start(server, user_name, {password: password, user_known_hosts_file: "/dev/null"}) do |ssh|
			volume_test1(ssh)
			volume_test2(ssh)
			volume_test3(ssh)
			static_pv_test4(ssh)
			dynamic_pvc_test5(ssh)
		end

  end

  private

	def volume_test1(ssh)
		puts "Back-to-back POD creation/deletion with the same volume source..."

		for iter in 0..4
			create_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 create -f /tmp/test1_updated.yaml"
			puts create_cmd
			output = ssh.exec!(create_cmd)
			puts output
			expect(output).to include("created")

			puts "Checking test1 status"
			if !check_kube_app_is_ready?(ssh, "nginx-test-1")
				puts "Kubernetes app test1 did not become READY after polling for status 300 iterations."
				#TODO: handle error case
			end

			puts "validate mounted volume"
			pre_iter = iter - 1
			if iter == 0
				output = validate_mount_path(ENV['KUBERNETES_WORKER1_IP'], "sdb", iter.to_s, pre_iter.to_s, false)
			else
				output = validate_mount_path(ENV['KUBERNETES_WORKER1_IP'], "sdb", iter.to_s, pre_iter.to_s, true)
			end
			expect(output).to eq true

			delete_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 delete -f /tmp/test1_updated.yaml"
			puts delete_cmd
			output = ssh.exec!(delete_cmd)
			puts output
			expect(output).to include("deleted")
			sleep(10)

			puts "Checking test1 status to be deleted"
			if !check_kube_app_is_deleted?(ssh, "nginx-test-1", "pods")
				puts "Kubernetes app test1 was not deleted after polling for status 300 iterations."
				#TODO: handle error case
			end
		end
	end

	def volume_test2(ssh)
		puts "Start 2nd test: Back-to-back POD creation/deletion with the different volume source.."

		for iter in 0..4
			puts "Start loop #{iter} for test2"
			if iter % 2 == 0
				type = "a"
			else
				type = "b"
			end
			create_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 create -f /tmp/test2#{type}_updated.yaml"
			puts create_cmd
			output = ssh.exec!(create_cmd)
			puts output
			expect(output).to include("created")

			puts "Checking test2 status"
			if !check_kube_app_is_ready?(ssh, "nginx-test-2#{type}")
				puts "Kubernetes app test2#{type} did not become READY after polling for status 300 iterations."
				#TODO: handle error case
			end

			puts "validate mounted volume"
			pre_iter = iter - 2
			if iter < 2
				output = validate_mount_path(ENV['KUBERNETES_WORKER1_IP'], "sdb", iter.to_s, pre_iter.to_s, false)
			else
				output = validate_mount_path(ENV['KUBERNETES_WORKER1_IP'], "sdb", iter.to_s, pre_iter.to_s, true)
			end
			expect(output).to eq true

			delete_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 delete -f /tmp/test2#{type}_updated.yaml"
			puts delete_cmd
			output = ssh.exec!(delete_cmd)
			puts output
			expect(output).to include("deleted")
			sleep(10)

			puts "Checking test2 status to be deleted"
			if !check_kube_app_is_deleted?(ssh, "nginx-test-2#{type}", "pods")
				puts "Kubernetes app test2#{type} was not deleted after polling for status 300 iterations."
				#TODO: handle error case
			end
		end

	end

	def volume_test3(ssh)
		puts "Start 3rd test: Single POD creation/deletion with the two volume sources..."

		create_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 create -f /tmp/test3_updated.yaml"
		puts create_cmd
		output = ssh.exec!(create_cmd)
		puts output
		expect(output).to include("created")

		puts "Checking test3 status"
		if !check_kube_app_is_ready?(ssh, "nginx-test-3")
			puts "Kubernetes app test3 did not become READY after polling for status 300 iterations."
			#TODO: handle error case
		end

		output = validate_mount_path(ENV['KUBERNETES_WORKER1_IP'], "sdb", "testa", "", false)
		expect(output).to eq true

		output = validate_mount_path(ENV['KUBERNETES_WORKER1_IP'], "sdc", "testb", "", false)
		expect(output).to eq true

		delete_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 delete -f /tmp/test3_updated.yaml"
		puts delete_cmd
		output = ssh.exec!(delete_cmd)
		puts output
		expect(output).to include("deleted")
		sleep(10)

		puts "Checking test3 status to be deleted"
		if !check_kube_app_is_deleted?(ssh, "nginx-test-3", "pods")
			puts "Kubernetes app test3 was not deleted after polling for status 300 iterations."
			#TODO: handle error case
		end
	end

	def static_pv_test4(ssh)
		puts "Start 4th test: Static Provisioning..."

		create_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 create -f /tmp/test4-pv_updated.yaml"
		puts create_cmd
		output = ssh.exec!(create_cmd)
		puts output
		expect(output).to include("created")
		puts "Checking test4 PV status"
		if !check_kube_pv_is_available?(ssh, "test4-pv")
			puts "Kubernetes test4 PV test4-pv did not become Available after polling for status 300 iterations."
			#TODO: handle error case
		end

		create_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 create -f /tmp/test4-pvc_updated.yaml"
		puts create_cmd
		output = ssh.exec!(create_cmd)
		puts output
		expect(output).to include("created")
		puts "Checking test4 PVC status"
		if !check_kube_pvc_is_bound?(ssh, "test4-pvc")
			puts "Kubernetes test4 PVC test4-pvc did not become Bound after polling for status 300 iterations."
			#TODO: handle error case
		end

		create_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 create -f /tmp/test4_updated.yaml"
		puts create_cmd
		output = ssh.exec!(create_cmd)
		puts output
		expect(output).to include("created")
		puts "Checking test4 app status"
		if !check_kube_app_is_ready?(ssh, "nginx-test-4")
			puts "Kubernetes test4 did not become READY after polling for status 300 iterations."
			#TODO: handle error case
		end

		output = validate_mount_path(ENV['KUBERNETES_WORKER1_IP'], "sdb", "test", "", false)
		expect(output).to eq true

		delete_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 delete -f /tmp/test4_updated.yaml"
		puts delete_cmd
		output = ssh.exec!(delete_cmd)
		puts output
		expect(output).to include("deleted")
		sleep(10)
		puts "Checking test4 app status to be deleted"
		if !check_kube_app_is_deleted?(ssh, "nginx-test-4", "pods")
			puts "Kubernetes app test4 was not deleted after polling for status 300 iterations."
			#TODO: handle error case
		end

		delete_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 delete -f /tmp/test4-pvc_updated.yaml"
		puts delete_cmd
		output = ssh.exec!(delete_cmd)
		puts output
		expect(output).to include("deleted")
		sleep(5)
		puts "Checking test4 PVC status to be deleted"
		if !check_kube_app_is_deleted?(ssh, "test4-pvc", "pvc")
			puts "Kubernetes app test4's PVC was not deleted after polling for status 300 iterations."
			#TODO: handle error case
		end

		delete_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 delete -f /tmp/test4-pv_updated.yaml"
		puts delete_cmd
		output = ssh.exec!(delete_cmd)
		puts output
		expect(output).to include("deleted")
		sleep(5)
		puts "Checking test4 PV status to be deleted"
		if !check_kube_app_is_deleted?(ssh, "test4-pv", "pv")
			puts "Kubernetes app test4's PV was not deleted after polling for status 300 iterations."
			#TODO: handle error case
		end
		sleep(10)
	end

	def dynamic_pvc_test5(ssh)
		puts "Start 5th test: Dynamic Provisioning..."

		create_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 create -f /tmp/test5-sc_updated.yaml"
		puts create_cmd
		output = ssh.exec!(create_cmd)
		puts output
		expect(output).to include("created")
		puts "Checking test5 Storage Class status"
		if !check_kube_sc_is_ready?(ssh, "test5-sc")
			puts "Kubernetes test5 Storage Class test4-sc did not exist after polling for status 300 iterations."
			#TODO: handle error case
		end

		create_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 create -f /tmp/test5-pvc_updated.yaml"
		puts create_cmd
		output = ssh.exec!(create_cmd)
		puts output
		expect(output).to include("created")
		puts "Checking test5 PVC status"
		if !check_kube_pvc_is_bound?(ssh, "test5-pvc")
			puts "Kubernetes test5 PVC test5-pvc did not become Bound after polling for status 300 iterations."
			#TODO: handle error case
		end

		create_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 create -f /tmp/test5a_updated.yaml"
		puts create_cmd
		output = ssh.exec!(create_cmd)
		puts output
		expect(output).to include("created")
		puts "Checking test5a app status"
		if !check_kube_app_is_ready?(ssh, "nginx-test-5a")
			puts "Kubernetes test5a did not become READY after polling for status 300 iterations."
			#TODO: handle error case
		end

		output = validate_mount_path(ENV['KUBERNETES_WORKER1_IP'], "sdb", "test5a", "", false)
		expect(output).to eq true
		sleep(10)

		delete_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 delete -f /tmp/test5a_updated.yaml"
		puts delete_cmd
		output = ssh.exec!(delete_cmd)
		puts output
		expect(output).to include("deleted")
		sleep(15)
		puts "Checking test5a app status to be deleted"
		if !check_kube_app_is_deleted?(ssh, "nginx-test-5a", "pods")
			puts "Kubernetes app test5a was not deleted after polling for status 300 iterations."
			#TODO: handle error case
		end

		create_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 create -f /tmp/test5b_updated.yaml"
		puts create_cmd
		output = ssh.exec!(create_cmd)
		puts output
		expect(output).to include("created")
		puts "Checking test5b app status"
		if !check_kube_app_is_ready?(ssh, "nginx-test-5b")
			puts "Kubernetes test5b did not become READY after polling for status 300 iterations."
			#TODO: handle error case
		end

		output = validate_mount_path(ENV['KUBERNETES_WORKER1_IP'], "sdb", "test5b", "test5a", true)
		expect(output).to eq true

		delete_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 delete -f /tmp/test5b_updated.yaml"
		puts delete_cmd
		output = ssh.exec!(delete_cmd)
		puts output
		expect(output).to include("deleted")
		sleep(15)
		puts "Checking test5b app status to be deleted"
		if !check_kube_app_is_deleted?(ssh, "nginx-test-5b", "pods")
			puts "Kubernetes app test5b was not deleted after polling for status 300 iterations."
			#TODO: handle error case
		end

		delete_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 delete -f /tmp/test5-pvc_updated.yaml"
		puts delete_cmd
		output = ssh.exec!(delete_cmd)
		puts output
		expect(output).to include("deleted")
		sleep(5)
		puts "Checking test5 PVC status to be deleted"
		if !check_kube_app_is_deleted?(ssh, "test5-pvc", "pvc")
			puts "Kubernetes app test5's PVC was not deleted after polling for status 300 iterations."
			#TODO: handle error case
		end

		delete_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 delete -f /tmp/test5-sc_updated.yaml"
		puts delete_cmd
		output = ssh.exec!(delete_cmd)
		puts output
		expect(output).to include("deleted")
		sleep(5)
		puts "Checking test5 Storage Class status to be deleted"
		if !check_kube_app_is_deleted?(ssh, "test5-sc", "storageclass")
			puts "Kubernetes app test5's Storage Class was not deleted after polling for status 300 iterations."
			#TODO: handle error case
		end

	end

	def validate_mount_path(node, device, new_content, old_content, check_content)
		Net::SSH.start(node, "root", :keys => ["/tmp/test_rsa"], :user_known_hosts_file => ["/dev/null"]) do |ssh|
			get_path_cmd = "df /dev/#{device} | tail -1 | awk '{ print $6 }'"
			mount_path = ssh.exec!(get_path_cmd)
			if mount_path == ""
				puts "Failed to locate mounted path of device sdb on #{node}"
				return false
			end
			puts "Mount path is #{mount_path}"
			file = mount_path.strip+"/test-data"
			if check_content
				check_cmd = "paste #{file}"
				output = ssh.exec!(check_cmd).strip
				if output != old_content
					puts "Old content in volume: #{output} doesn't match with string: #{old_content}"
					return false
				end
			end
			puts "Write content #{new_content} into file #{file}"
			write_cmd = "echo #{new_content} > #{file}"
			output = ssh.exec!(write_cmd)
			if output != nil
				puts "Failed to write new content into mounted path file, output: #{output}"
				return false
			end
			puts "Before wait content to be written"
			sleep(20)
		end
		return true
	end

	def check_kube_app_is_ready?(ssh, test_pod_name)
		retry_max = 300
		retry_cnt = 0
		while retry_cnt < retry_max
			check_status_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 get pods #{test_pod_name}"
			output = ssh.exec!(check_status_cmd)
			if output.include? "Running"
				puts "Pod #{test_pod_name} is running"
				return true
			end
			retry_cnt = retry_cnt + 1
		end
		return false
	end

	def check_kube_pv_is_available?(ssh, pv_name)
		retry_max = 300
		retry_cnt = 0
		while retry_cnt < retry_max
			check_status_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 get pv #{pv_name}"
			output = ssh.exec!(check_status_cmd)
			if output.include? "Available"
				puts "PV #{pv_name} is available"
				return true
			end
			retry_cnt = retry_cnt + 1
		end
		return false
	end

	def check_kube_pvc_is_bound?(ssh, pvc_name)
		retry_max = 300
		retry_cnt = 0
		while retry_cnt < retry_max
			check_status_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 get pvc #{pvc_name}"
			output = ssh.exec!(check_status_cmd)
			if output.include? "Bound"
				puts "PVC #{pvc_name} is bound"
				return true
			end
			retry_cnt = retry_cnt + 1
		end
		return false
	end

	def check_kube_sc_is_ready?(ssh, sc_name)
		retry_max = 300
		retry_cnt = 0
		while retry_cnt < retry_max
			check_status_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 get storageclass #{sc_name}"
			output = ssh.exec!(check_status_cmd)
			if output.include? "#{sc_name}"
				puts "Storage Class #{sc_name} is created"
				return true
			end
			retry_cnt = retry_cnt + 1
		end
		return false
	end

	def check_kube_app_is_deleted?(ssh, name, type)
		retry_max = 300
		retry_cnt = 0
		while retry_cnt < retry_max
			check_status_cmd = "./kubectl -s http://#{ENV['KUBERNETES_MASTER_IP']}:8080 get #{type} #{name}"
			output = ssh.exec!(check_status_cmd)
			if output.include? "not found" 
				puts "#{type} #{name} is deleted"
				return true
			end
			retry_cnt = retry_cnt + 1
		end
		return false
	end

	def populate_yaml_files()
		puts "Populate yaml files"

		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test1.yaml"
		content = File.read(path)
		content["$KUBERNETES_PDID1"] = ENV["KUBERNETES_PDID1"]
		new_path = "/tmp/test1_updated.yaml"

		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test2a.yaml"
		content = File.read(path)
		content["$KUBERNETES_PDID1"] = ENV["KUBERNETES_PDID1"]
		new_path = "/tmp/test2a_updated.yaml"
		File.write(new_path, content)
		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test2b.yaml"
		content = File.read(path)
		content["$KUBERNETES_PDID2"] = ENV["KUBERNETES_PDID2"]
		new_path = "/tmp/test2b_updated.yaml"
		File.write(new_path, content)

		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test3.yaml"
		content = File.read(path)
		content["$KUBERNETES_PDID1"] = ENV["KUBERNETES_PDID1"]
		content["$KUBERNETES_PDID2"] = ENV["KUBERNETES_PDID2"]
		new_path = "/tmp/test3_updated.yaml"
		File.write(new_path, content)

		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test4-pv.yaml"
		content = File.read(path)
		content["$KUBERNETES_PDID1"] = ENV["KUBERNETES_PDID1"]
		new_path = "/tmp/test4-pv_updated.yaml"
		File.write(new_path, content)
		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test4-pvc.yaml"
		content = File.read(path)
		new_path = "/tmp/test4-pvc_updated.yaml"
		File.write(new_path, content)
		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test4.yaml"
		content = File.read(path)
		new_path = "/tmp/test4_updated.yaml"
		File.write(new_path, content)

		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test5-sc.yaml"
		content = File.read(path)
		content["$KUBERNETES_SC_FLAVOR"] = ENV["KUBERNETES_SC_FLAVOR"]
		new_path = "/tmp/test5-sc_updated.yaml"
		File.write(new_path, content)
		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test5-pvc.yaml"
		content = File.read(path)
		new_path = "/tmp/test5-pvc_updated.yaml"
		File.write(new_path, content)
		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test5a.yaml"
		content = File.read(path)
		new_path = "/tmp/test5a_updated.yaml"
		File.write(new_path, content)
		path = "#{ENV['WORKSPACE']}/ruby/integration_tests/spec/api/cluster/test5b.yaml"
		content = File.read(path)
		new_path = "/tmp/test5b_updated.yaml"
		File.write(new_path, content)

		puts "Copying updated yaml files from local machine to management vm"
		copy_yaml_cmd = "sshpass -p \"vmware\" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/*_updated.yaml esxcloud@#{ENV['API_ADDRESS']}:/tmp/"
		puts copy_yaml_cmd
		`#{copy_yaml_cmd}`
	end

	def copy_over_the_kubectl_from_master_node_to_devbox(ssh)
		puts "copying the kubectl from master node to local"
		scp_cmd = "sudo scp -i /tmp/test_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@#{ENV['KUBERNETES_MASTER_IP']}:~/kubectl ~/"
		puts scp_cmd
		output = ssh.exec!(scp_cmd)
		puts output

		puts "changing permission for kubectl"
		chmod_cmd = "sudo chmod +x kubectl"
		puts chmod_cmd
		output = ssh.exec!(chmod_cmd)
		puts output
	end

	# Curl to the Kubernetes api using env_master_ip to make sure that it is responding.
	# Check that there is exactly expect_node number of nodes from the api response
	# Node that the expected_node includes the master node for kubernetes
	def validate_kube_api_responding(env_master_ip, expected_node_count)
		puts "Validate Kubernetes api is responding"
		kube_end_point = "http://" + env_master_ip + ":8080"
		http_helper=EsxCloud::HttpClient.new(kube_end_point)
		response = http_helper.get("/api/v1/nodes")
		expect(response.code).to be 200
		total_node_count = JSON.parse(response.body)['items'].size
		# kubenetes api keeps an entry for any nodes it ever created. If one of the
		# creation failed, the entry would still be in items.
		# From observation, our resize_cluster code actually wipe out all existing worker
		# and create new ones. Thus, the entry for node_info would be at least at big
		# for the expected_node_count.
		expect(total_node_count.to_i).to be > expected_node_count - 1
	end

  # Removes a worker VM and check that trigger maintenance can recreate deleted VMs
  def validate_trigger_maintenance(master_ip, total_worker_count, cluster)
    vm = get_random_worker_vm(cluster)
    puts "Stopping random Kubernetes worker node: #{vm.name}"
    vm.stop!
    vm.delete
    wait_for_kube_worker_count(master_ip, total_worker_count - 1, 5, 120)
    client.trigger_maintenance(cluster.id)
    wait_for_kube_worker_count(master_ip, total_worker_count, 5, 120)
  end

  # This function validate that our cluster manager api is working properly
  # It also checks that the extended properties added later were put it properly
  def validate_kube_cluster_info(cluster_current, expected_worker_count, flavor)
    cid_current = cluster_current.id
    cluster_current = client.find_cluster_by_id(cid_current)
    expect(cluster_current.name).to start_with("kubernetes-")
    expect(cluster_current.type).to eq("KUBERNETES")
    expect(cluster_current.worker_count).to eq expected_worker_count
    expect(cluster_current.state).to eq "READY"
    expect(cluster_current.master_vm_flavor).to eq flavor
    expect(cluster_current.other_vm_flavor).to eq flavor
    expect(cluster_current.image_id).to eq @kubernetes_image.id
    expect(cluster_current.extended_properties["cluster_version"]).not_to be_empty
    expect(cluster_current.extended_properties.length).to be > 12
  end

  # Waits for the Kubernetes API to report the number of active worker nodes to be target_worker_count
  def wait_for_kube_worker_count(master_ip, target_worker_count, retry_interval, retry_count)
    puts "Waiting for Kubernetes client to report available worker count #{target_worker_count}"
    worker_count = get_active_worker_node_count(master_ip)

    until worker_count == target_worker_count || retry_count == 0 do
      sleep retry_interval
      worker_count = get_active_worker_node_count(master_ip)
      retry_count -= 1
    end

    fail("Kubernetes at #{master_ip} failed to report #{target_worker_count} workers in time") if retry_count == 0
  end

  # Returns the number of active worker nodes reported by the Kubernetes API
  def get_active_worker_node_count(master_ip)
    kube_end_point = "http://" + master_ip + ":8080"
    http_helper=EsxCloud::HttpClient.new(kube_end_point)
    response = http_helper.get("/api/v1/nodes")
    expect(response.code).to be 200
    worker_node_count = 0

    JSON.parse(response.body)['items'].each do |item|
      # Check that the node is a worker
      if item['metadata']['labels']['vm-hostname'].start_with?("worker")
        conditions = item['status']['conditions']
        conditions.each do |condition|
          # Check that the node is ready
          if condition['type'] == "Ready" && condition['status'] == "True"
            worker_node_count += 1
          end
        end
      end
    end
    return worker_node_count
  end

  # Gets a worker vm from the specified cluster
  # Returns a VM
  def get_random_worker_vm(cluster)
    client.get_cluster_vms(cluster.id).items.each do |vm|
      if vm.name.start_with?("worker")
         return vm
      end
    end

    fail("No worker vms found for cluster #{cluster.id}")
  end

end
