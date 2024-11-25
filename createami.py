import boto3
import logging
from datetime import datetime

# Initialize logger
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize EC2 client
ec2_client = boto3.client('ec2')


def lambda_handler(event, context):
    # Replace 'instance_id' with the actual EC2 instance ID or retrieve it from the event
    instance_id = event.get('instance_id', 'i-0ffde92882f347773')
    timestamp = datetime.now().strftime("%Y-%m-%d-%H-%M-%S")
    ami_name = event.get('ami_name', f'AutomatedAMI-{timestamp}')

    try:
        # Create an AMI from the instance
        response = ec2_client.create_image(
            InstanceId=instance_id,
            Name=ami_name,
            NoReboot=True,
            TagSpecifications=[
                {
                    'ResourceType': 'image',
                    'Tags': [
                        {
                            'Key': 'Name',
                            'Value': 'VRGuru-Backup'
                        }
                    ]
                }
            ]
        )

        ami_id = response['ImageId']
        logger.info(f"AMI created successfully: {ami_id}")
        return {
            'statusCode': 200,
            'message': 'AMI created successfully',
            'ami_id': ami_id
        }

    except Exception as e:
        logger.error(f"Error creating AMI: {e}")
        return {
            'statusCode': 500,
            'message': f'Error creating AMI: {e}'
        }
