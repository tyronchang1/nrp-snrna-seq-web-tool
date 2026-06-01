import boto3
import os

s3 = boto3.client("s3", region_name="us-east-2")
local = "/home/ec2-user/backend/all_WT_iMN_no_harmony_050826.rds"

if not os.path.exists(local):
    print("Downloading RDS from S3...")
    s3.download_file("nrp-snrna-seq", "iMN/all_WT_iMN_no_harmony_050826.rds", local)
    print("Download complete.")
else:
    print("RDS already exists, skipping download.")
