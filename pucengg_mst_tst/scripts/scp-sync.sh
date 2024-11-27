#!/bin/bash

set +x

function export_mst_creds {
	export AWS_REGION=us-east-1
	export AWS_ACCESS_KEY_ID=${SCP_AWS_ACCESS_KEY_ID}
	export AWS_SECRET_ACCESS_KEY=${SCP_AWS_SECRET_ACCESS_KEY}
	export AWS_SESSION_TOKEN=${SCP_AWS_SESSION_TOKEN}
}



export_mst_creds
aws organizations list-policies --filter="SERVICE_CONTROL_POLICY" > scps.json
#cat scps.json
files_to_be_synced=$(ls -1 *.json | grep ${pattern})
echo "==================================="
echo "Below SCP's will be synced to AWS"
echo "==================================="
echo "${files_to_be_synced}"
echo "================================="

for scp in $(echo "${files_to_be_synced}")
do
	scp_name=$( echo ${scp} | sed 's#.json##g')
	scp_id=$(cat scps.json | jq --arg scpname "$scp_name" -r '.Policies[] | select(.Name==$scpname) | .Id')
	if [ -n "${scp_id}" ]; then
		echo "Syncing scp $scp_name with $scp_id in AWS Organizations"
        aws organizations update-policy --policy-id $scp_id --content file://$scp
	else
		echo "SCP $scp_name not found in AWS Organizations"
		#exit 1
	fi
done
