#!/bin/bash

oc login https://your.openshift.env:8443 -u $USERNAME -p $PASSWORD --insecure-skip-tls-verify > /dev/null

results=()

for project in $PROJECTS
do
    # Login to the OpenShfit project for the WordPress Site
    oc project ${project} > /dev/null
    
    # Get a pod to use to run the CLI command on
    pod=$(oc get pods -o name | cut -c 5- | grep -v "build" | grep cms- -m 1) > /dev/null
    
    # Connect to the pod, execute the wp-cli command, and save the result
    sites=$(oc exec $pod -- wp site list --format=ids --skip-themes --skip-plugins --skip-packages | wc -w)

	  echo 
    echo "${project} has ${sites}"
	  echo    
   
done

oc logout > /dev/null
