#!/bin/bash


function export_rccscpeditor_creds {
	export AWS_REGION=us-east-1
	export AWS_ACCESS_KEY_ID=""
	export AWS_SECRET_ACCESS_KEY=""
	export AWS_SESSION_TOKEN=""
	
	echo "Assuming to RRCC_AWS_SCPEDITOR role"
	aws sts assume-role --role-arn "arn:aws:iam::304512965277:role/RRCC_AWS_SCPEDITOR" --role-session-name "RCCSCPEDITOR" > session-details.json
	export AWS_ACCESS_KEY_ID=$(cat session-details.json | jq -r '.Credentials.AccessKeyId')
	export AWS_SECRET_ACCESS_KEY=$(cat session-details.json | jq -r '.Credentials.SecretAccessKey')
	export AWS_SESSION_TOKEN=$(cat session-details.json | jq -r '.Credentials.SessionToken')
}

function export_mst_creds {
	export_rccscpeditor_creds
	
	echo "Assuming to RMST_AWS_SCPEDITOR role"
	aws sts assume-role --role-arn "arn:aws:iam::569336190782:role/RMST_AWS_SCPEDITOR" --role-session-name "MSTSCPEDITOR" > session-details.json
	export AWS_ACCESS_KEY_ID=$(cat session-details.json | jq -r '.Credentials.AccessKeyId')
	export AWS_SECRET_ACCESS_KEY=$(cat session-details.json | jq -r '.Credentials.SecretAccessKey')
	export AWS_SESSION_TOKEN=$(cat session-details.json | jq -r '.Credentials.SessionToken')
}

changelog_s3_bucket="novartisrccgbieinfra001"
aws_console_scp_base_url="https://us-east-1.console.aws.amazon.com/organizations/v2/home/policies/service-control-policy"



function check_and_exit {
	local status_code=$1
	local message=$2
	if [ $status_code -ne 0 ]; then
		echo "FAILED: ${message}"
		exit 1
	fi
	return 0
}

function get_scp_targets_names(){
	local scp_id="$1"
    aws organizations list-targets-for-policy --policy-id="$scp_id" | jq -r '.Targets[] | "\(.Name)"'
}

# get last applied version from s3 bucket
export_rccscpeditor_creds
aws s3 cp s3://${changelog_s3_bucket}/SCPAutomation/childdata.json .
aws s3 cp s3://${changelog_s3_bucket}/SCPAutomation/appliedversions.json .

if ! [ -f "${WORKSPACE}/childdata.json" ]; then
	echo "childdata.json file not found to get the last applied version... Quitting"
    exit 1
fi

last_applied_version=$(cat appliedversions.json | jq -r '.appliedversions | last | .commitId')
modified_files=$(git diff --name-only --diff-filter=ACMRT $last_applied_version HEAD | grep 'json$' | grep -v appliedversions)


if [[ -z "${modified_files}" ]]; then
	echo "No SCP changes to apply... Exiting.."
	exit 0
else
	echo "Last applied version: ${last_applied_version}"
	echo "Current version: `git rev-parse HEAD`"
	echo -e "Changed files: \n${modified_files}"
fi

export_mst_creds
aws organizations list-policies --filter="SERVICE_CONTROL_POLICY" > scps.json
if [ $? -ne 0 ]; then
	echo "Fetching scp list failed..."
	exit 1
fi

scp_targets=""

# working on changed files
for f in `echo "$modified_files"`
do	
	scp_name=$( echo ${f} | sed 's#.json##g')
	scp_id=$(cat scps.json | jq --arg scpname "$scp_name" -r '.Policies[] | select(.Name==$scpname) | .Id')
	if [ -n "${scp_id}" ]; then
		echo "Obtaining scp targets for $scp_name with $scp_id from AWS Organizations"
		for target in `get_scp_targets_names $scp_id`
		do
			scp_targets="${scp_targets},${target}"
		done
	else
		echo "SCP $scp_name not found in AWS Organizations"
		exit 1
	fi
done

python3 ${WORKSPACE}/scripts/getChildData.py $scp_targets ${WORKSPACE}/childdata.json