Instructions on how to deploy the Automox agent using the SentinelOne console. 

Deployment Overview

1. Choose the correct script for deployment
2. Edit the access key in the deployment script
3. Upload script(s) to S1 Console
4. Bulk deploy to all devices running the same OS
5. Choose devices to run deployment policy across
6. See the results of the policy execution 


Choose the correct script for deployment
   - S1 can deploy the Automox agent to Windows, Mac, and Linux devices. You first need to select the scripts you’ll need to deploy to the devices. These        scripts are availble in this repo for each OS.
    

Edit the Automox Agent Access Key 
   - You will need to add your Automox Agent Access Key to the script before moving on to the next step. 
   - The agent access key can be found in the Key section of the Automox console


Upload script(s) to S1 Console
   - Once you have the script(s) edited with the agent access key, you can then upload them to the Automation script library within the S1 console. 
   - Navigate to the Automation section within the S1 console and go to “Script Library” tab at the top
   - Next, select Upload New Script
   - From here, you’ll need to fill out the top section and then upload the script for the OS you want to deploy.
   - After you upload the script, scroll to the bottom and select "Upload Script".  
   - Walk through the Script Configuration wizard and hit Submit
   - You will now see the script uploaded in the script library. 
   - Do this for each OS you want to deploy Automox to. 

     
Bulk deploy to all devices running the same OS
   - You can also run this Automation script across all devices in the console that are on the same OS version. 
   - Note: this will deploy Automox to ALL devices that are running the same OS in the same site. 
   - Navigate to the Automation section within the S1 console and go to “Script Library” tab at the top. 
   - From there click on the run button beside the script you want to execute.
   - Hit the play biutton and it will start the deployment. 
   - If you hover over the play button, it will tell you how many devices are in scope for the policy.


Choose devices to run deployment policy across
   - This section explains how to select individual devices for the deployment
   - Navigate to the Sentinels section of the S1 console 
   - From here, select the devices you want to deploy Automox to. Note: make sure these devices are running the same OS 
   - Once the devices are selected, click on the Actions dropdown button and navigate to Response -> Run Script
   - You can now select the Automox deployment Automation policy you created earlier to run across only the devices you have selected
   - The script will execute across all of the selected devices. 


See the results of the policy execution 
   - After the script runs, you’ll want to analyze the results to see the success and failure reponses 
   - Navigate to the Automation section in the S1 console and click on Tasks tab at the very top 
   - This will list all of the script executions you have done over a period of time
   - Select the script you ran by clicking on the Task Name. This will take you to the results page for the script. 
   - From here you will be able to see the results of the script on each device it runs across.
