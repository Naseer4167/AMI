import boto3
import logging
from datetime import datetime, timedelta

# Initialize logger
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize EC2 client
ec2_client = boto3.client('ec2')

# Set the retention period (e.g., 7 days)
RETENTION_DAYS = 0

def lambda_handler(event, context):
    try:
        # Calculate the date for retention
        retention_date = datetime.now() - timedelta(days=RETENTION_DAYS)

        # Describe all AMIs created by your account
        images = ec2_client.describe_images(Owners=['self'])['Images']

        for image in images:
            creation_date = datetime.strptime(image['CreationDate'], '%Y-%m-%dT%H:%M:%S.%fZ')
            if creation_date < retention_date:
                ami_id = image['ImageId']
                logger.info(f"Deregistering AMI: {ami_id}")

                # Deregister the AMI
                ec2_client.deregister_image(ImageId=ami_id)

                # Delete associated snapshots
                if 'BlockDeviceMappings' in image:
                    for block_device in image['BlockDeviceMappings']:
                        if 'Ebs' in block_device and 'SnapshotId' in block_device['Ebs']:
                            snapshot_id = block_device['Ebs']['SnapshotId']
                            ec2_client.delete_snapshot(SnapshotId=snapshot_id)
                            logger.info(f"Snapshot deleted successfully: {snapshot_id}")

        return {
            'statusCode': 200,
            'message': 'Old AMIs and associated snapshots deleted successfully'
        }

    except Exception as e:
        logger.error(f"Error deleting old AMIs: {e}")
        return {
            'statusCode': 500,
            'message': f'Error deleting old AMIs: {e}'
        }
