import boto3
import json
import sys
from prettytable import PrettyTable



target_ous = sys.argv[1]
source_data_file = sys.argv[2]

# reading source data 
source_file_contents = open( source_data_file )
data = json.load(source_file_contents)
source_file_contents.close()


def getChildAccounts( parent, accountlist ):
    accounts = data[parent]['accounts']
    if accounts:
        for account in accounts:
            accountlist.append(account)
    return accountlist

def getChildOU( parent, ous, acc ):
    accounts = data[parent]['accounts']
    if accounts:
        for account in accounts:
            acc.append(account)
    for OU in data[parent]['OU']:
        ous.append(OU)
        acc = getChildAccounts( OU, acc )
        getChildOU(OU, ous, acc)
    return ous,acc



master_ou_list = []
master_account_list = []

# collecting all the OU and accounts for the given targets
for target_ou in target_ous.split(','):
    if target_ou != '':
        ous, accounts = getChildOU( target_ou, [], [] )
        for ou in ous:
            if ou not in master_ou_list:
                master_ou_list.append(ou)

        for account in accounts:
            if account not in master_account_list:
                master_account_list.append(account)

ou_table = PrettyTable(['Impacting Organizations Units'])
account_table = PrettyTable(['Impacting Accounts'])


for ou in master_ou_list:
    ou_table.add_row([ou])
    
for ou in master_account_list:
    account_table.add_row([ou])

print(ou_table)
print(account_table)