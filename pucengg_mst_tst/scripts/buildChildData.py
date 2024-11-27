import boto3
import json

session = boto3.Session()
client = session.client('organizations', region_name='us-east-1')

rootId="r-rri7"

overall_map = {}
def returnChildOU( parentId, nextToken ):
    if nextToken == '':
        response = client.list_children(
            ParentId=parentId,
            ChildType='ORGANIZATIONAL_UNIT',
            MaxResults=10
        )
    else:
        response = client.list_children(
        ParentId=parentId,
        ChildType='ORGANIZATIONAL_UNIT',
        NextToken=nextToken
        ) 
    return response
    
def getChildAccounts( parentId ):
	response = client.list_children(
		ParentId=parentId,
		ChildType='ACCOUNT'
	)
	return response
    
	
def returnOUName( ouId ):
    response = client.describe_organizational_unit(OrganizationalUnitId=ouId)
    return response['OrganizationalUnit']['Name']

def returnAccountName( Id ):
    response = client.describe_account(AccountId=Id)
    return response['Account']['Name']

def getChildren( parent ):
    childOU = {}
    response = returnChildOU( parent, '' )
    if response['Children'] != []:
        for child in response['Children']:
            childOU[child['Id']]=returnOUName(child['Id'])
            
    if 'NextToken' in response:
        while response['NextToken'] != "null":
            response = returnChildOU( parent,  response['NextToken'])
            if response['Children'] != []:
                for child in response['Children']:
                    childOU[child['Id']]=returnOUName(child['Id'])
            if 'NextToken' not in response:
                break
            
    return childOU
    


children = getChildren( rootId )
while children:
    nextChild = {}
    for childid,child in children.items():
        nextChildOUList = []
        for k,v in getChildren(childid).items():
            print(f"{k} ==> {v}")
            nextChild[k] = v
            nextChildOUList.append(v)
        accounts_response = getChildAccounts( childid  )
        overall_map[child] = {"OU": "", "accounts": ""}
        overall_map[child]['OU'] = nextChildOUList
        accounts_under_child = accounts_response['Children']
        account_list = []
        for account in accounts_under_child:
            account_list.append(returnAccountName(account['Id']))
        overall_map[child]['accounts'] = account_list
    children = nextChild
    #break
    
with open("childdata.json", "w") as outfile:
    json.dump(overall_map, outfile, indent = 3)