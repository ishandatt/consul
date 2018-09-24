##Script to restart a service, after acquiring consul lock, after consul-template has changed the config
##Working config backup is taken by consul-template
##consul-template changes the existing config based on changes done in the consul-kv

####Author: Ishan Datt
####Date: 24 Sept 2018

#!/bin/bash

SECONDS=0

consul_host=""
consul_port=8500
consul_path="/opt/consul/0.7.2/consul"

key_for_lock="service/<service_name>/leader"

backup_config_path=""
current_config_path=""

slack_hook=""

service_host_name=""
service_port=""
service_health_check_uri=""

create_consul_session()
{
	echo "Creating session."
	session_ID=$(curl -s -X PUT \
		       -d "{ \
			      \"Name\": \"Service-Lock\",
	                      \"Node\": \"$(hostname)\",
			      \"Behavior\": \"release\",
			      \"TTL\": \"600s\"
			   }" \
		       http://$consul_host:$consul_port/v1/session/create | jq -r ".ID")
        echo $session_ID
}

extend_consul_session()
{
	echo "Extending session by 10 more minutes."
        session_ID="$1"
        session_destroyed=$(curl -s -X PUT \
                              http://$consul_host:$consul_port/v1/session/renew/$session_ID)
}

destroy_consul_session()
{
	echo "Destroying session."
	session_ID="$1"
	session_destroyed=$(curl -s -X PUT \
		              http://$consul_host:$consul_port/v1/session/destroy/$session_ID)
        echo $session_destroyed	
}

acquire_consul_lock()
{
        echo "Trying to acquire lock."
	session_ID="$1"
	lock_acquired=$(curl -s -X PUT \
                          -d "{ \
                                 \"Node\": \"$(hostname)\",
                                 \"Description\": \"Lock for restart after config change by consul-kv.\"
                              }" \
                          http://$consul_host:$consul_port/v1/kv/$key_for_lock?acquire=$session_ID)
	echo $lock_acquired
}

release_consul_lock()
{
        echo "Releasing acquired lock."
        session_ID="$1"
        lock_released=$(curl -s -X PUT \
                            http://$consul_host:$consul_port/v1/kv/$key_for_lock?release=$session_ID)
	echo $lock_released
}

enable_disable_maintenance()
{
	enable_disable="$1"
	echo "$enable_disable maintenance mode for node."
	$consul_path maint -$enable_disable
}

service_restart()
{
	echo "Restarting service."
	/etc/init.d/service -w 300 restart
}

verify_service()
{
	echo "Verifying service status."
	service_http_code=0
        check_count=0
        while [[ $service_http_code -ne 200 && $check_count -lt 36 ]]; do
                sleep 5
                service_http_code=`curl -s -w "%{http_code}" https://$service_host_name:$service_port/$service_health_check_uri | tail -1 | sed 's/}//'`
                let check_count+=1
                if [ $check_count -eq 36 ]; then
                        echo 10
                fi
        done
}

rollback_to_previous_config()
{
	echo "Rolling back to previous config."
	rm -f $current_config_path
	mv $backup_config_path $current_config_path

}

notify_slack()
{
	curl -X POST $slack_hook \
          -d "{
                 \"text\": \"$1\"
              }"
}

session_ID=`create_consul_session`

while [ $SECONDS -lt 1800 ]; do
	if [[ `acquire_consul_lock $session_ID` == true ]]; then
		echo "Consul lock has been acquired. Taking node out of consul."
		notify_slack "$(hostname): Consul lock has been acquired. Taking node out of consul."
		enable_disable_maintenance "enable"

		echo "Sleeping for 31 seconds for kong cache to clear."
		notify_slack "$(hostname): Sleeping for 31 seconds for kong cache to clear."
		sleep 31
	
		echo "Restarting service."
		notify_slack "$(hostname): Restarting service."
		service_restart
	
		echo "Verifying successful service restart after new config."
		notify_slack "$(hostname): Verifying successful service restart after new config."
		if [[ `verify_service` == 10 ]]; then
			echo "Service did not give positive response while waiting for 3 minutes. Rolling back and restarting service."
			notify_slack "$(hostname): Service did not give positive response while waiting for 3 minutes. Rolling back and restarting service."
			rollback_to_previous_config
			service_restart
			echo "Verifying successful service restart after rolling back to old config."
			notify_slack "$(hostname): Verifying successful service restart after rolling back to old config."
			if [[ `verify_service` == 10 ]]; then
				echo "Service did not give positive response while waiting for 3 minutes even after rolling back to old config."
				echo "Extending log held by 10 more minutes to avoid total downtime on all nodes and exiting script."
				echo "Please kill the process on other nodes to prevent downtime and investigate."
				notify_slack "$(hostname): Service did not give positive response while waiting for 3 minutes even after rolling back to old config."
				notify_slack "$(hostname): Extending log held by 10 more minutes to avoid total downtime on all nodes and exiting script."
				notify_slack "$(hostname): Please kill the process on other nodes to prevent downtime and investigate."
	                        extend_consul_session $session_ID
				exit 20
			else
				echo "Service successfully restarted with the old config."
				echo "Releasing lock."
				notify_slack "$(hostname): Service successfully restarted with the old config."
				notify_slack "$(hostname): Releasing lock."
				release_consul_lock $session_ID
				echo "Destroying consul session."
				notify_slack "$(hostname): Destroying consul session."
				destroy_consul_session $session_ID
				echo "Putting node back in consul."
				notify_slack "$(hostname): Putting node back in consul."
				enable_disable_maintenance "disable"
				exit 30
			fi
		else
		        echo "Service successfully restarted with the new config."
	                echo "Releasing lock."
		        notify_slack "$(hostname): Service successfully restarted with the new config."
	                notify_slack "$(hostname): Releasing lock."
	                release_consul_lock $session_ID
	                echo "Destroying consul session."
	                notify_slack "$(hostname): Destroying consul session."
	                destroy_consul_session $session_ID
	                echo "Putting node back in consul."
	                notify_slack "$(hostname): Putting node back in consul."
	                enable_disable_maintenance "disable"
	                exit 0
		fi
	else
		echo "Consul lock could not be acquired. Some other node is holding the lock."
		notify_slack "$(hostname): Consul lock could not be acquired. Some other node is holding the lock."
		echo "Destroying session."
		destroy_consul_session $session_ID
		echo "Sleeping for 30 seconds before trying again."
		notify_slack "$(hostname):Sleeping for 30 seconds before trying again."
		sleep 30
	fi
done

echo "The node could not acquire a lock in 30 minutes. Changing back to old config file and exiting."
echo "Please investigate."
notify_slack "$(hostname): The node could not acquire a lock in 30 minutes. Changing back to old config file and exiting."
notify_slack "$(hostname): Please investigate."

rollback_to_previous_config

exit 40
