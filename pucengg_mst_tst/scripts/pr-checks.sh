#!/bin/bash

set +x
export AWS_REGION=us-east-1

BITBUCKET_USERNAME=$1
BITBUCKET_PASSWORD=$2

echo "Assuming to RRCC_AWS_SCPEDITOR role"
aws sts assume-role --role-arn "arn:aws:iam::304512965277:role/RRCC_AWS_SCPEDITOR" --role-session-name "RCCSCPEDITOR" > session-details.json
export AWS_ACCESS_KEY_ID=$(cat session-details.json | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(cat session-details.json | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(cat session-details.json | jq -r '.Credentials.SessionToken')


echo "Assuming to RMST_AWS_SCPEDITOR role"
aws sts assume-role --role-arn "arn:aws:iam::569336190782:role/RMST_AWS_SCPEDITOR" --role-session-name "MSTSCPEDITOR" > session-details.json
export AWS_ACCESS_KEY_ID=$(cat session-details.json | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(cat session-details.json | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(cat session-details.json | jq -r '.Credentials.SessionToken')

function post_comment(){
	local pr_link="$1"
	local msg="$2"
    echo $msg
    curl -k -u "$BITBUCKET_USERNAME:$BITBUCKET_PASSWORD" \
     -H 'Content-type: application/json' \
     -X POST "$pr_link/comments" \
     -d "{\"text\": \"$msg\"}"
	if [ $? -ne 0 ]; then
		echo "Comment posting to bitbucket failed.."
		exit 1
	fi
}

function get_scp_targets(){
	local scp_id="$1"
    aws organizations list-targets-for-policy --policy-id="$scp_id" | jq -r '.Targets[] | "\(.Name),\(.TargetId)"'
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

if [ -z "$BITBUCKET_PULL_REQUEST_LINK" ]; then
	echo "Build required BITBUCKET_PULL_REQUEST_LINK to proceed, this value is empty. It may be due to you triggered this build manually. This build is intended to be triggered automatically from bitbucket PR"
	exit 1
fi

BITBUCKET_ENDPOINT=$(echo "$BITBUCKET_PULL_REQUEST_LINK" | awk -F/ '{ print $3}')
BITBUCKET_BASE_URL="https://${BITBUCKET_ENDPOINT}"
PROJECT_KEY=$(echo "$BITBUCKET_PULL_REQUEST_LINK" | awk -F/ '{ print $5}')
REPOSITORY_NAME=$(echo "$BITBUCKET_PULL_REQUEST_LINK" | awk -F/ '{ print $7}')
# reset all the approvers who approved this PR already, since there is new change. Reset is required
if [ "$BITBUCKET_X_EVENT" = "pr:from_ref_updated" ]; then
	echo "Source Branch in PR got updated, Need to reset reviewers if already approved"
	# Get all the reviewers who approved the PR already
	approved_reviewers=$(curl -u "$BITBUCKET_USERNAME:$BITBUCKET_PASSWORD" --silent \
	--request GET \
	--url "${BITBUCKET_BASE_URL}/rest/api/latest/projects/${PROJECT_KEY}/repos/$REPOSITORY_NAME/pull-requests/${BITBUCKET_PULL_REQUEST_ID}/participants" \
	--header 'Accept: application/json' \
	| jq -r '.values[] | select(.status=="APPROVED") | select(.role=="REVIEWER") | "\(.user.slug),\(.user.name)"')
	if [ -n "${approved_reviewers}" ]; then
		for approver in `echo "${approved_reviewers}"`; do
			approver_slug=$(echo $approver | cut -d, -f1)
			approver_name=$(echo $approver | cut -d, -f2)
			echo "Removing approver from PR - Name: $approver_name, Slug: $approver_slug"
			curl -u "$BITBUCKET_USERNAME:$BITBUCKET_PASSWORD" --request DELETE \
			--url "${BITBUCKET_BASE_URL}/rest/api/latest/projects/${PROJECT_KEY}/repos/$REPOSITORY_NAME/pull-requests/${BITBUCKET_PULL_REQUEST_ID}/participants/${approver_slug}"
			echo "Adding approver again to PR - Name: $approver_name, Slug: $approver_slug"
			curl -u "$BITBUCKET_USERNAME:$BITBUCKET_PASSWORD" --request POST \
			  --url "${BITBUCKET_BASE_URL}/rest/api/latest/projects/${PROJECT_KEY}/repos/$REPOSITORY_NAME/pull-requests/${BITBUCKET_PULL_REQUEST_ID}/participants" \
			  --header 'Accept: application/json' \
			  --header 'Content-Type: application/json' \
			  --data "{
			  \"role\": \"REVIEWER\",
			  \"user\": {
				\"slug\": \"${approver_slug}\",
				\"name\": \"${approver_name}\"
			  }
			  }"
 
		done
	else
		echo "No reviewers has approved the PR yet, so no reset done"
	fi
fi

comments_link=$(echo $BITBUCKET_PULL_REQUEST_LINK | sed 's#https://bitbucketenterprise.aws.novartis.net#https://bitbucketenterprise.aws.novartis.net/rest/api/1.0#g')
git config  user.email "scpautomation@novartis.net"
git config user.name "SCP Automation"

git checkout master
master_head_commit=$(git rev-parse --short HEAD)
git checkout $BITBUCKET_SOURCE_BRANCH
source_head_commit=$(git rev-parse --short HEAD)
git merge origin/master
if [ $? -ne 0 ]; then
	echo "Merging $BITBUCKET_SOURCE_BRANCH to master failed..."
    post_comment $comments_link "Merging $BITBUCKET_SOURCE_BRANCH to master failed... :-("
    exit 1
fi

changed_files=$(git diff --name-only --diff-filter=ACMRT $master_head_commit $source_head_commit | grep json | grep -v appliedversions)
added_files=$(git diff --name-only --diff-filter=A $master_head_commit $source_head_commit | grep json | grep -v appliedversions)
deleted_files=$(git diff --name-only --diff-filter=D $master_head_commit $source_head_commit | grep json | grep -v appliedversions)
renamed_files=$(git diff --name-status --diff-filter=R $master_head_commit $source_head_commit | grep json | grep -v appliedversions)

if [ -z "${changed_files}" ]; then
	post_comment $comments_link "No SCP json files changes in this PR :-("
	exit 0
fi

is_tst_branch="false"

if [[ "$BITBUCKET_SOURCE_BRANCH" == tst/* ]]; then
	is_tst_branch="true" 
fi

echo "Is Test branch: $is_tst_branch"

## Checking if tst/* branch has files from gb/pgb
for f in `echo "$changed_files"`
do
	if [[ "$f" == SCPNVSORGU1*.json ]] && [ "${is_tst_branch}" = "true" ]; then 
    	post_comment $comments_link "SCP $f is for GB OU, this change should not be raised in PR for tst/* branch. Please create branch with prefix gb/* and provide PR. :-("
        exit 1
    elif [[ "$f" == SCPNVSORGU2*.json ]] && [ "${is_tst_branch}" = "true" ]; then 
    	post_comment $comments_link "SCP $f is for PGB OU, this change should not be raised in PR for tst/* branch. Please create branch with prefix gb/* and provide PR. :-("
        exit 1
    fi
done

## Naming convention validation
for f in `echo "$changed_files"`
do
	if [[ "$f" == SCPNVSORGU*.json ]]; then 
    	continue
    else
    	post_comment $comments_link "### SCP $f, doesn't follow Novartis SCP Naming standard - SCP need to start with SCPNVSORGU."
        exit 1
    fi
done


## Json validation starting
json_validation_success="true"
failed_jsons=""
for f in `echo "$changed_files"`
do
	echo "Json validation for ${f}"
    cat $f | jq empty
    if [ $? -ne 0 ]; then
      json_validation_success="false"
      failed_jsons="$failed_jsons $f"
	fi
done


if [ "${json_validation_success}" = "false" ]; then
	echo "json file is not in correct format for $failed_jsons"
    post_comment $comments_link "Json file validation failed for $failed_jsons :-("
    exit 1
else
	post_comment $comments_link "Json file validation got success. :-)"
fi
echo ""

## Check character limit for SCP's
json_char_count_success="true"
failed_jsons=""
for f in `echo "$changed_files"`
do
	echo "Json character count validation for ${f}"
    char_in_json=$(cat $f | sed -e 's/[[:space:]]//g' -e 's/[[:blank:]]//g' | tr -d '\n' | wc -c)
    if [ ${char_in_json} -gt 5119 ]; then
      json_char_count_success="false"
      failed_jsons="$failed_jsons $f"
	fi
done


if [ "${json_char_count_success}" = "false" ]; then
	echo "Json char limit for SCP is 5120bytes, these json has more than 5120bytes $failed_jsons"
    post_comment $comments_link "Json char limit for SCP is 5120bytes, these json has more than 5120bytes $failed_jsons :-("
    exit 1
else
	post_comment $comments_link "All SCP's are under size limit. :-)"
fi
echo ""


## update the targets for the updated SCP
## How many targets are going to be affected
## in which level this SCP is present

aws organizations list-policies --filter="SERVICE_CONTROL_POLICY" > scps.json
for f in `echo "$changed_files"`
do
	echo "Getting targets for scp ${scp_name}"
	scp_name=$( echo ${f} | sed 's#.json##g')
    is_scp_renamed=$(echo "${renamed_files}" | grep $scp_name)
    if [ -n "${is_scp_renamed}" ]; then
    	filename_before_rename=$(echo "${is_scp_renamed}" | awk '{ print $2}')
        current_file_name=$(echo "${is_scp_renamed}" | awk '{ print $3}')
        post_comment $comments_link "**Failure: SCP $filename_before_rename renamed as $current_file_name. Rename option is not supported in this workflow.**"
        exit 1
        #continue
    fi
    is_new_scp_added=$(echo "${added_files}" | grep $scp_name)
    if [ -n "${is_new_scp_added}" ]; then
        if is_scp_exists $scp_name ; then
			post_comment $comments_link "### SCP with name $scp_name already exist in console, Added now in bitbucket. It will be taken as update instead of creation."
		else		
			post_comment $comments_link "### New SCP with name $scp_name will be created, No Targets will be attached- Need to attach targets manually."
		fi
        continue
    fi
    scp_id=$(cat scps.json | jq --arg scpname "$scp_name" -r '.Policies[] | select(.Name==$scpname) | .Id')
    if [ -n "${scp_id}" ]; then
    	scp_targets=`get_scp_targets $scp_id | sort`
        message_string=""
        for target in `echo "$scp_targets"`
        do
        	target_name=$(echo $target | cut -d, -f1)
            target_id=$(echo $target | cut -d, -f2)
            if [[ $target_id == ou* ]]; then
            	link_target="organizational-units"
            else
            	link_target="accounts"
            fi
            message_string="$message_string \n [$target_name](https://us-east-1.console.aws.amazon.com/organizations/v2/home/$link_target/${target_id})"
        done
        post_comment $comments_link "### Targets for changed SCP [$scp_name](https://us-east-1.console.aws.amazon.com/organizations/v2/home/policies/service-control-policy/${scp_id}) ${message_string}"
    else
        post_comment $comments_link "### Could not able to find the SCP $scp_name in AWS Organizations.."
        exit 1
    fi
done


# update the duplicate actions in scp
found_duplicate_actions="false"
for f in `echo "$changed_files"`
do
	duplicate_message=$(python3 ${WORKSPACE}/scripts/find-duplicate-actions.py ${f})
    if [ -n "${duplicate_message}" ]; then
		post_comment $comments_link "${f} SCP - $duplicate_message"
        found_duplicate_actions="true"
	fi
done

if [ "${found_duplicate_actions}" = "true" ]; then
    exit 1
fi


## update whether the change is for GB, PGB or TST OU... so that certain people approval is not needed..
message_about_environment=""
for f in `echo "$changed_files"`
do	
	scp_name=$( echo ${f} | sed 's#.json##g')
    echo "Getting targets for scp ${scp_name}"
    if [[ $scp_name == SCPNVSORGU1* ]]; then
    	message_about_environment="$message_about_environment **Production-GB**"
    elif [[ $scp_name == SCPNVSORGU2* ]]; then
    	message_about_environment="$message_about_environment **PreProduction-PGB**"
    elif [[ $scp_name == SCPNVSORGU3* ]]; then
    	message_about_environment="$message_about_environment **Test-TST**"
    fi  
done

echo "envmsg"
echo "${message_about_environment}"

envs=$(echo "${message_about_environment}" | tr ' ' '\n' |sort | uniq | tr '\n' ',' | sed -e 's#^,##g' -e 's#,$##g')
if [ -n "${envs}" ]; then
	post_comment $comments_link "### In this request, changes are initiated for below environments. \n$envs"
else
	post_comment $comments_link "### Environments such as GB,PGB and TST could not be identified from naming conventions of changed SCP's."
fi

if [ -n "${deleted_files}" ]; then
	post_comment $comments_link "### This request has some **Deleted** SCP's. Deleting in Bitbucket wont delete in AWS console. \n$deleted_files"
fi


## Check if the scp is a valid scp, by doing a dry run against dummy scp in AWS console

# Create dryrunscp
jq -n '{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Action": "*",
			"Resource": "*"
		}
	]
}' > dryrunscp.json

echo ""
dryrunscpname="dryrunscp"
dryrunscpid=$(cat scps.json | jq --arg dryrunscpname "$dryrunscpname" -r '.Policies[] | select(.Name==$dryrunscpname) | .Id')
if [ -z "${dryrunscpid}" ]; then
	echo "Creating dry run scp policy .."
	scp_creation_output=$(aws organizations create-policy --name $dryrunscpname  --type SERVICE_CONTROL_POLICY --content file://dryrunscp.json --description "dry run policy")
	check_and_exit $? "Dryrun scp creation failed .."
	dryrunscpid=$(echo $scp_creation_output | jq -r '.Policy.PolicySummary.Id')
	echo "Dry run scp id: $dryrunscpid"
else
	echo "Dry run scp policy with id $dryrunscpid already exists.."
fi

found_issues_in_dryrun="false"
for f in `echo "$changed_files"`
do	
	scp_name=$( echo ${f} )
    echo "Performing dry run for scp ${scp_name}"
    cat $scp_name | sed -e 's/[[:space:]]//g' -e 's/[[:blank:]]//g' | tr -d '\n' > ${scp_name}-spaceremoved
	dryrun_output=$(aws organizations update-policy --policy-id $dryrunscpid --content file://${scp_name}-spaceremoved 2>&1)
	if [ $? -ne 0 ]; then
		found_issues_in_dryrun="true"
		message=$(echo "${dryrun_output}" | tr -d '\n')
		post_comment $comments_link "Dryrun failed for $scp_name with output: \n $message"
	else
		echo "Dry run update for $scp_name got success."
	fi
done

echo "Deleting dry run scp policy with id - $dryrunscpid"
aws organizations delete-policy --policy-id $dryrunscpid

if [ "${found_issues_in_dryrun}" = "true" ]; then
	echo "Found some errors in dryrun.. failing pipeline"
    exit 1
fi