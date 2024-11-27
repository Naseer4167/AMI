#!/bin/bash

set +x

function export_mst_creds {
	export AWS_REGION=us-east-1
	export AWS_ACCESS_KEY_ID=${SCP_AWS_ACCESS_KEY_ID}
	export AWS_SECRET_ACCESS_KEY=${SCP_AWS_SECRET_ACCESS_KEY}
	export AWS_SESSION_TOKEN=${SCP_AWS_SESSION_TOKEN}
}

function export_s3bucket_creds {
	export AWS_REGION=us-east-1
	export AWS_ACCESS_KEY_ID=${BUCKET_AWS_ACCESS_KEY_ID}
	export AWS_SECRET_ACCESS_KEY=${BUCKET_AWS_SECRET_ACCESS_KEY}
	export AWS_SESSION_TOKEN=${BUCKET_AWS_SESSION_TOKEN}
}

changelog_s3_bucket="${changelog_s3_bucket}"
s3_bucket_kms_key="${changelog_s3_bucket_kms_key_arn}"


function copy_file_to_bucket {
    set -e
	local key=$1
    local filepath=$2
    
    export_s3bucket_creds
    aws s3api put-object \
	--bucket  $changelog_s3_bucket\
	--key $key \
	--server-side-encryption aws:kms \
	--ssekms-key-id $s3_bucket_kms_key \
	--body $filepath
    export_mst_creds
    set +e
}


function save_scp {
    set -e
	local policy_name=$1
	local policy_id=$2
    local action=$3
    aws organizations describe-policy --policy-id $policy_id --query Policy.Content | jq -r . | jq . > backup/${policy_name}.json
    if [ $? -eq 0 ]; then
    	copy_file_to_bucket $BUILD_NUMBER/backup/${policy_name}-${action}.json backup/${policy_name}.json
		set +e
    	return 0
    else
		set +e
    	return 1
    fi
    
}

# get last applied version from s3 bucket
export_s3bucket_creds
aws s3 cp s3://${changelog_s3_bucket}/appliedversions.json .


last_applied_jenkinsbuild=$(cat appliedversions.json | jq -r '.appliedversions | last | .jenkinsBuildNumber')

last_applied_jenkinsbuild="175"
aws s3 cp s3://${changelog_s3_bucket}/"${last_applied_jenkinsbuild}"/changelog.txt .

echo "==================================="
echo "Below are the changes for Rollback"
echo "==================================="
cat changelog.txt
echo "================================="

while IFS= read -r line
do
  applied_action=$(echo "$line" | cut -d, -f1)
  scp_name=$(echo "$line" | cut -d, -f2)
  scp_id=$(echo "$line" | cut -d, -f3)
  old_scp_name=$(echo "$line" | cut -d, -f4)
  if [ "${applied_action}" = "CREATE" ]; then
	echo "Newly created SCP ${scp_name}  won't be rolled back."
  elif [ "${applied_action}" = "RENAME" ]; then
    echo "SCP to be renamed from ${scp_name} to ${old_scp_name}"
	aws s3 cp "s3://${changelog_s3_bucket}/${last_applied_jenkinsbuild}/backup/${old_scp_name}-RENAME.json" .
	#aws organizations update-policy --policy-id $scp_id --name $old_scp_name --content file://${old_scp_name}-RENAME.json
  elif [ "${applied_action}" = "UPDATE" ]; then
    echo "Updating SCP ${scp_name} - ${scp_id}"
	aws s3 cp "s3://${changelog_s3_bucket}/${last_applied_jenkinsbuild}/backup/${scp_name}-UPDATE.json" .
	#aws organizations update-policy --policy-id $scp_id --content file://${scp_name}-UPDATE.json
  fi
done < changelog.txt

export_mst_creds

