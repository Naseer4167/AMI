import json, sys
from os import path
import collections

inputfile = sys.argv[1]

if not(path.exists(inputfile)):
    sys.exit(f"Given file {inputfile} not exists")
 
f = open(inputfile)
jsoncontents = json.load(f)

statement_counter = 1
for statement in jsoncontents["Statement"]:
    if "Action" in statement:
        action = statement["Action"]
    elif "NotAction" in statement:
        action = statement["NotAction"]
    
    if "Sid" in statement:
        statementName = statement["Sid"]
    else:
        statementName = f"Statement{statement_counter}"
    if not isinstance(action, list):
        break
    duplicate_action = [item for item, count in collections.Counter(action).items() if count > 1]
    if len(duplicate_action) > 0:
        duplicate_string = ','.join(duplicate_action)
        print(f"{statementName} has some duplicates {duplicate_string}")
    statement_counter += 1
