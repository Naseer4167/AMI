#!/bin/bash


changelog_s3_bucket="novartisrccgbieinfra001"

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




function copy_file_to_bucket {
    set -e
	local key=$1
    local filepath=$2
    
    export_rccscpeditor_creds
    aws s3api put-object \
	--bucket  $changelog_s3_bucket\
	--key $key \
	--server-side-encryption aws:kms \
	--body $filepath
    set +e
}


export_mst_creds

python3 buildChildData.py

# push the childdata to s3 bucket
copy_file_to_bucket SCPAutomation/childdata.json childdata.json