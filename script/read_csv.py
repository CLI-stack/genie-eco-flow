"""
Created on Fri May 25 13:30:23 2023
@author: Simon Chen
"""
# This script is to add the original content as quotation
import argparse
import csv
import os
import time
import re
parser = argparse.ArgumentParser(description='Update task csv item')
parser.add_argument('--csv',type=str, default = "None",required=True,help="the csv file")
args = parser.parse_args()
# time,tag,sender,subject,mailBody,mailQuote,reply,instruction,runDir,status
with open(args.csv,encoding='utf-8-sig') as f:
    reader = csv.reader(f)
    # here reader cannot be assign to taskMail directly, otherwise report IO error
    for i in reader:
        print(",".join(i))
            
    f.close

