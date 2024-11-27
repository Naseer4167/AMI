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

function copy_file_to_bucket {
    set -e
	local key=$1
    local filepath=$2
    
    export_rccscpeditor_creds
    aws s3api put-object \
	--bucket  $changelog_s3_bucket\
	--key SCPAutomation/TST/$key \
	--server-side-encryption aws:kms \
	--body $filepath
    export_mst_creds
    set +e
}


function save_scp {
    set -e
	local policy_name=$1
	local policy_id=$2
    local action=$3
	cp ${WORKSPACE}/${policy_name}.json ${WORKSPACE}/currentversion/
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

function is_scp_exists(){
	local scpname="$1"
	scpid=$(cat scps.json | jq --arg scpname "$scp_name" -r '.Policies[] | select(.Name==$scpname) | .Id')
	if [ -n "${scpid}" ]; then
		return 0
	else
		return 1
	fi
}

function check_and_exit {
	local status_code=$1
	local message=$2
	if [ $status_code -ne 0 ]; then
		echo "FAILED: ${message}"
		exit 1
	fi
	return 0
}

# get last applied version from s3 bucket
export_rccscpeditor_creds
aws s3 cp s3://${changelog_s3_bucket}/SCPAutomation/TST/appliedversions.json .

if ! [ -f "${WORKSPACE}/appliedversions.json" ]; then
	echo "appliedversions.json file not found to get the last applied version... Quitting"
    exit 1
fi

last_applied_version=$(cat appliedversions.json | jq -r '.appliedversions | last | .commitId')
changed_files=$(git diff --name-only --diff-filter=CMT $last_applied_version HEAD | grep 'json$' | grep -v appliedversions)
renamed_files=$(git diff --name-status --diff-filter=R $last_applied_version HEAD | grep 'json$' | grep -v appliedversions)
added_files=$(git diff --name-only --diff-filter=A $last_applied_version HEAD | grep 'json$' | grep -v appliedversions)

mkdir -p backup currentversion

if [[ -z "${changed_files}" ]] && [[ -z "${renamed_files}" ]] && [[ -z "${added_files}" ]]; then
	echo "No SCP changes to apply... Exiting..."
	exit 0
else
	echo "Last applied version: ${last_applied_version}"
	echo "Current version: `git rev-parse HEAD`"
	echo -e "Changed files: \n${changed_files}"
	echo -e "Renamed files: \n${renamed_files}"
	echo -e "New SCP's: \n${added_files}"
fi

touch changelog.txt
export_mst_creds
aws organizations list-policies --filter="SERVICE_CONTROL_POLICY" > scps.json
if [ $? -ne 0 ]; then
	echo "Fetching scp list failed..."
	exit 1
fi

# working on changed files
for f in `echo "$changed_files"`
do	
	scp_name=$( echo ${f} | sed 's#.json##g')
	scp_id=$(cat scps.json | jq --arg scpname "$scp_name" -r '.Policies[] | select(.Name==$scpname) | .Id')
	cat $f | sed -e 's/[[:space:]]//g' -e 's/[[:blank:]]//g' | tr -d '\n' > ${f}-spaceremoved
	if [ -n "${scp_id}" ]; then
		echo "Updating scp $scp_name with $scp_id in AWS Organizations"
        save_scp $scp_name $scp_id "UPDATE" || exit 1
        aws organizations update-policy --policy-id $scp_id --content file://${f}-spaceremoved
        check_and_exit $? "updating $scp_name $scp_id failed .."
        copy_file_to_bucket $BUILD_NUMBER/afterchange/${scp_name}-UPDATE.json ${f}-spaceremoved
        echo "UPDATE,${scp_name},${scp_id}" >> changelog.txt
		echo "Updated ${scp_name} - ${aws_console_scp_base_url}/${scp_id}"
	else
		echo "SCP $scp_name not found in AWS Organizations"
        echo "ERROR,${scp_name},SCP_NOT_FOUND" >> changelog.txt
		exit 1
	fi
done


# working on newly added files
for f in `echo "$added_files"`
do	
	scp_name=$( echo ${f} | sed 's#.json##g')
	if is_scp_exists $scp_name ; then
		scp_id=$(cat scps.json | jq --arg scpname "$scp_name" -r '.Policies[] | select(.Name==$scpname) | .Id')
		cat $f | sed -e 's/[[:space:]]//g' -e 's/[[:blank:]]//g' | tr -d '\n' > ${f}-spaceremoved
		echo "Updating scp $scp_name with $scp_id in AWS Organizations"
		save_scp $scp_name $scp_id "UPDATE" || exit 1
		aws organizations update-policy --policy-id $scp_id --content file://${f}-spaceremoved
		check_and_exit $? "updating $scp_name $scp_id failed .."
		copy_file_to_bucket $BUILD_NUMBER/afterchange/${scp_name}-UPDATE.json ${f}-spaceremoved
		echo "UPDATE,${scp_name},${scp_id}" >> changelog.txt
		echo "Updated ${scp_name} - ${aws_console_scp_base_url}/${scp_id}"
	else
		echo "Creating scp $scp_name in AWS Organizations"
		aws organizations create-policy --name $scp_name --type SERVICE_CONTROL_POLICY --content file://$f --description "$scp_name"
		check_and_exit $? "Creating $scp_name failed .."
		copy_file_to_bucket $BUILD_NUMBER/afterchange/${scp_name}-CREATE.json $f
		echo "CREATE,${scp_name}" >> changelog.txt
	fi
done

# working on renamed scp files
old_IFS=$IFS
IFS=$'\n'
for f in `echo $renamed_files`
do	
    filename_before_rename=$(echo "${f}" | awk '{ print $2}' | sed 's#.json##g')
    current_file_name=$(echo "${f}" | awk '{ print $3}' | sed 's#.json##g')
	scp_id=$(cat scps.json | jq --arg scpname "$filename_before_rename" -r '.Policies[] | select(.Name==$scpname) | .Id')
	if [ -n "${scp_id}" ]; then
    	echo "SCP renamed from $filename_before_rename as $current_file_name - Updating the policy contents in $scp_id"
        save_scp $filename_before_rename $scp_id "RENAME" || exit 1
        aws organizations update-policy --policy-id $scp_id --name $current_file_name --content file://${current_file_name}.json
		check_and_exit $? "updating/renaming $scp_name $scp_id failed .."
        copy_file_to_bucket $BUILD_NUMBER/afterchange/${current_file_name}-RENAME.json ${current_file_name}.json
        echo "RENAME,${current_file_name},${scp_id},${filename_before_rename}" >> changelog.txt
		echo "Renamed ${current_file_name} - ${aws_console_scp_base_url}/${scp_id}"
	else
		echo "SCP $filename_before_rename not found in AWS Organizations"
        echo "ERROR,${scp_name},SCP_NOT_FOUND" >> changelog.txt
		exit 1
	fi
done
IFS=${old_IFS}

# pushing applied commit and changelog to s3
headversion=$(git rev-parse HEAD)
datetime=$(date)
jenkinsBuildLink=$BUILD_URL
jenkinsBuildNumber=$BUILD_NUMBER
commitId=$headversion
set -e
jq --arg datetime "$datetime"   --arg jenkinsBuildLink "$jenkinsBuildLink" --arg jenkinsBuildNumber "$jenkinsBuildNumber" --arg commitId "$commitId" '.appliedversions[.appliedversions| length] |= . + {
  "date": $datetime, 
  "jenkinsBuildLink" : $jenkinsBuildLink,
  "commitId": $commitId,
  "jenkinsBuildNumber": $jenkinsBuildNumber
}' appliedversions.json > newappliedversions.json
mv newappliedversions.json appliedversions.json

cat changelog.txt

echo "Copying updated appliedversion.json to s3"
copy_file_to_bucket appliedversions.json appliedversions.json

echo "Copying changelog to s3"
copy_file_to_bucket $BUILD_NUMBER/changelog.txt changelog.txt


