#!/bin/bash

#
# Any variable prefixed with site_ refers to the multisite.   
# Any variable prefixed with blog_ refers to the site.
#
# the empty echo statement are for spacing and output new lines


echo
echo "#"
echo "# Settings"
echo "#"
echo

echo "Domain: ${DOMAIN}"
echo "Site Path: ${SITE_PATH}"
echo "Source: ${SOURCE_PROJECT}"
echo
echo "#"
echo "# Getting current site information .... "
echo "#"

oc login https://your.openshift.env -u $USERNAME -p $PASSWORD --insecure-skip-tls-verify > /dev/null
oc project ${SOURCE_PROJECT} > /dev/null
source_pod=$(oc get pods -o name | cut -c 5- | grep -v "build" | grep  -m 1) > /dev/null

echo
echo "Source Pod: ${source_pod}"

source_db=$(oc exec $source_pod -- wp --skip-themes --skip-plugins --skip-packages config get DB_NAME)
echo
echo "Database: ${source_db}"

source_root_prefix=$(oc exec $source_pod -- wp --skip-themes --skip-plugins --skip-packages config get table_prefix)
echo
echo "Root Prefix: ${source_root_prefix}"

source_site_id=$(oc exec $source_pod -- wp --skip-themes --skip-plugins --skip-packages config get SITE_ID_CURRENT_SITE)
echo
echo "Site ID: ${source_site_id}"

if [[ ${SITE_PATH} == '/' ]]; then
    sql_path='/'
    slug=${DOMAIN}
    blog_url="${DOMAIN}.ecu.edu"
else
	sql_path="/${SITE_PATH}/"
	blog_url="${DOMAIN}.ecu.edu/${SITE_PATH}"
	slug="${DOMAIN}_${SITE_PATH}"
fi

echo 
echo "Blog URL: ${blog_url}"
echo

source_blog_id=$(oc exec $source_pod -- wp --skip-themes --skip-plugins --skip-packages db query --skip-column-names "SELECT blog_id FROM ${source_db}.${source_root_prefix}blogs WHERE domain = '${DOMAIN}.ecu.edu' AND path = '${sql_path}'")
echo
echo "SQL: SELECT blog_id FROM ${source_db}.${source_root_prefix}blogs WHERE domain = '${DOMAIN}.ecu.edu' AND path = '${sql_path}'"
echo 
echo "Blog ID:"
echo $source_blog_id
echo

if [ -z "$source_blog_id" ] 
then
        echo 
        echo "Check your domain, site path, and source!   Could not find the site!"
        echo 
        exit 1
fi

# Clean up in case earlier migration may have failed

echo
echo "Cleaning up orphaned files in case previous builds failed."
rm ssh.txt > /dev/null
rm wordpress_migration.sql > /dev/null
rm user_export.csv > /dev/null

echo
echo "#"
echo "# Starting Migration!"
echo "#"

#
# Export Site Settings
#

echo
echo "#"
echo "# Exporting site Network Settings ...."
echo "#"

source_blog_upload_space=$(oc exec $source_pod -- wp network meta get ${source_site_id} blog_upload_space --skip-themes --skip-plugins --skip-packages)
source_fileupload_maxk=$(oc exec $source_pod -- wp network meta get ${source_site_id} fileupload_maxk --skip-themes --skip-plugins --skip-packages)

echo
echo "blog_upload_space: ${source_blog_upload_space}"
echo "fileupload_maxk: ${source_fileupload_maxk}"
echo

# Catch if user list is empty.
if [ -z "$source_fileupload_maxk" ] || [ -z "$source_blog_upload_space" ]
then
   source_fileupload_maxk=102400
   source_blog_upload_space=200
fi

echo
echo "#"
echo "# Exporting Blog Information.... "
echo "#"
   
#
# Export Site
#
# This includes database multisite settings tables, users, roles, and capabilities
#
echo 
echo "#"
echo "# Exporting Site Tables...."
echo "#"
source_blog_prefix=$(oc exec $source_pod -- wp --skip-themes --skip-plugins --skip-packages db prefix --url=${blog_url})

echo 
echo "Source Site Table Prefix: ${source_blog_prefix}"
echo 
# Catch if prefix is empty.
if [ -z "$source_blog_prefix" ] 
then
    oc logout > /dev/null
    echo 
    echo "Something happened because the old prefix is empty!  Stopping the job!"
    echo 
    exit 1
fi

#Have to escape _ in mysql queries.  Replacing _ with \_
escaped_underscore="${source_blog_prefix/%_/\_}"

site_tables=$(oc exec $source_pod -- wp --skip-themes --skip-plugins --skip-packages db query "SHOW TABLES LIKE '${escaped_underscore}%'" --url=${blog_url} --skip-column-names | xargs | tr " " ",")

# Catch if tables is empty.
if [ -z "$site_tables" ] 
then
    oc logout > /dev/null
    echo
    echo "Something happened because no tables were found to export!  Stopping the job!"
    echo
    exit 1
fi

echo 
echo "Site Tables to Export: ${site_tables}"
echo 

     
oc exec $source_pod -- wp --skip-themes --skip-plugins --skip-packages db export wordpress_migration.sql --tables=${site_tables} --lock-tables=false --skip-add-locks
echo 
echo "#"
echo "# Export site tables ..."
echo "#"

echo
echo "Copy migration script to Jenkkins"
oc cp $source_pod:/opt/app-root/src/wordpress_migration.sql wordpress_migration.sql > /dev/null 
echo "Delete migration script from pod"
oc exec $source_pod -- rm wordpress_migration.sql > /dev/null
echo

echo 
echo "#"
echo "# Exporting site activated plugins ...."
echo "#"

blog_plugins=$(oc exec $source_pod -- wp plugin list --url=${blog_url} --status=active --field=name --skip-themes --skip-plugins --skip-packages)
echo 
echo "Blog Plugins: ${blog_plugins}"
echo 

#
# Export Users
#

echo 
echo "#" 
echo "# Exporting Users, Roles, and Capabilities ...."
echo "#"

oc exec $source_pod -- wp --skip-themes --skip-plugins --skip-packages user list --url=${blog_url} --format=csv --fields=ID,user_login,display_name,user_email,user_registered > user_export.csv
oc cp $source_pod:/opt/app-root/src/user_export.csv user_export.csv > /dev/null 
oc exec $source_pod -- rm user_export.csv > /dev/null

#User list to iterate so content can be reassigned to users new user id
user_list=$(oc exec $source_pod -- wp --skip-themes --skip-plugins --skip-packages user list --url=${blog_url} --fields=ID,user_login,roles)

echo 
echo "User List: ${user_list}"
echo 
# Catch if user list is empty.
if [ -z "$user_list" ] 
then
    oc logout > /dev/null
    echo 
    echo "Something happened because the user list is empty!  Stopping the job!"
    echo 
    exit 1
fi


# Check if export was successful or not by check if file exists and is not empty.
echo 
if [ -s "user_export.csv" ] && [ -s "wordpress_migration.sql" ] 
then 
   echo "Successfully exported the site tables and users!"
else
   oc logout > /dev/null
   echo "There was an issue exporting the site tables and/or users! Stopping Job!"
   exit 1
fi
echo 

# Building post and ninja form upload author index; needed when the post is assigned to the authors new id in the new site.
echo 
echo "#"
echo "# Building Author Index for Posts...."
echo "#"

post_authors=$(oc exec $source_pod -- wp db query "SELECT DISTINCT post_author FROM ${source_db}.${source_blog_prefix}posts WHERE post_author != 0" --url=${blog_url} --skip-column-names --skip-themes --skip-plugins --skip-packages)

echo 
echo "Post Authors IDs: ${post_authors}"
echo 

#Loop author ids and create a array with id as index and value is a comma seperated list of post IDs.
if [ ! -z "$post_authors" ] 
then
    declare -A author_posts
    while read -r source_user_id; do
     
        author_posts[$source_user_id]=$(oc exec $source_pod -- wp db query "SELECT ID FROM ${source_db}.${source_blog_prefix}posts WHERE post_author = ${source_user_id}" --url=${blog_url} --skip-column-names --skip-themes --skip-plugins --skip-packages  | xargs | tr " " ",")
        echo 
        echo "User ${source_user_id} has ${author_posts[$source_user_id]} post(s)"
        echo
        
    done <<< "$post_authors"
fi

echo 
echo "#"
echo "# Building Submission Index for Ninja Form Uploads...."
echo "#"

submission_users=$(oc exec $source_pod -- wp db query "SELECT DISTINCT user_id FROM ${source_db}.${source_blog_prefix}ninja_forms_uploads WHERE user_id != 0" --url=${blog_url} --skip-column-names --skip-themes --skip-plugins --skip-packages)

echo 
echo "Submission User IDs for Ninja Form Uploads: ${submission_users}"
echo 

#Loop submission user ids and create a array with id as index and value is a comma seperated list of submission IDs.
if [ ! -z "$submission_users" ] 
then
    declare -A user_submissions
    while read -r source_user_id; do
     
        user_submissions[$source_user_id]=$(oc exec $source_pod -- wp db query "SELECT id FROM ${source_db}.${source_blog_prefix}ninja_forms_uploads WHERE user_id = ${source_user_id}" --url=${blog_url} --skip-column-names --skip-themes --skip-plugins --skip-packages  | xargs | tr " " ",")
        echo 
        echo "User ${source_user_id} has ${user_submissions[$source_user_id]} submission(s)"
        echo          
    done <<< "$submission_users"
else
    echo 
    echo "No Ninja Form Uploads!"
    echo 
fi



#
# Create New Site
#
oc logout > /dev/null
oc login https://eascloud.ecu.edu:8443 -u $USERNAME -p $PASSWORD --insecure-skip-tls-verify > /dev/null
oc project ms-dev > /dev/null
destination_pod=$(oc get pods -o name | cut -c 5- | grep -v "build" | grep  -m 1) > /dev/null

echo 
echo "#" 
echo "# Creating New Site...."
echo "#"


echo 
echo "Destination Pod: ${destination_pod}"
echo 
oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages site create --slug=${slug}

destination_blog_prefix=$(oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages db prefix --url=wordpressdev.ecu.edu/${slug}/) > /dev/null
destination_root_prefix=$(oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages config get table_prefix)
destination_db=$(oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages config get DB_NAME)
destination_blog_id=$(oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages db query --skip-column-names "SELECT blog_id FROM ${destination_db}.${destination_root_prefix}blogs WHERE domain = 'wordpressdev.ecu.edu' AND path = '/${slug}/'")
destination_site_id=$(oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages db query --skip-column-names "SELECT site_id FROM ${destination_db}.${destination_root_prefix}blogs WHERE domain = 'wordpressdev.ecu.edu' AND path = '/${slug}/'")

echo 
echo "MultiSite Id:  ${destination_site_id}"
echo "Site Id:  ${destination_blog_id}"
echo "Root Prefix: ${destination_root_prefix}"
echo "Database: ${destination_db}"
echo "Site Prefix: ${destination_blog_prefix}"
echo 

# Catch if prefix is empty.
if [ -z "$destination_db" ] || [ -z "$destination_blog_prefix" ] || [ -z "$destination_site_id" ] || [ -z "$destination_blog_id" ] || [ -z "$destination_root_prefix" ]
then
    oc logout > /dev/null
    rm wordpress_migration.sql > /dev/null
    echo 
    echo "Something happened can't get new site information!  Stopping the job!  If the new site already exists check to see if you need to delete it or it has already been migrated."
    echo 
    exit 1
fi


#
# Update URL in database
#


echo 
echo "#"
echo "# Updating New Site URL to Old Site URL...."
echo "#" 
    
oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages option --url=wordpressdev.ecu.edu/${slug} update home "https://${blog_url}"
oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages option --url=wordpressdev.ecu.edu/${slug} update siteurl "https://${blog_url}"
oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages db query "UPDATE ${destination_db}.${destination_root_prefix}blogs SET domain='${DOMAIN}.ecu.edu', path='${sql_path}' WHERE blog_id='${destination_blog_id}'"

echo 
echo "wordpressdev.ecu.edu/${slug} blog entry updated to domain='${DOMAIN}.ecu.edu' and path='${sql_path}'"
echo 

#
# Flush Redis
#
echo 
echo "#"
echo "# Flush Redis ...."
echo "#"
oc exec $destination_pod -- wp cache flush --skip-themes --skip-plugins --skip-packages 

# Not importing the roles as no easy way to mass export.   They should all match what is created here.  If this changes the it is important 
# to update the role and capabilities here to avoid import errors.
#
# Create Roles
# These have to exist before importing users

echo 
echo "#"
echo "# Create Roles...."
echo "#" 

oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages role create --url=${blog_url} itcs_support "ITCS Support"
oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages role create --url=${blog_url} blog_owner "Blog Owner"

#
#  Assign capabilities to roles
# 

echo 
echo "#"
echo "# Add capabilities to roles...."
echo "#"

blog_owner_cap="...."
itcs_support_cap="${blog_owner_cap} ... "

echo 
oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages cap add --url=${blog_url} blog_owner ${blog_owner_cap}
oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages cap add --url=${blog_url} itcs_support ${itcs_support_cap}
echo 

#
# Create User Accounts
#

echo 
echo "#"
echo "# Import User Accounts ...."
echo "#"

echo 
oc cp user_export.csv $destination_pod:/opt/app-root/src
oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages user import-csv --url=${blog_url} --skip-update user_export.csv
oc exec $destination_pod -- rm user_export.csv
rm user_export.csv
echo 

#
# Import Site SQL
#

echo
echo "#"
echo "# Importing Site Content...."
echo "#" 

echo 
echo "Search and Replace ${source_blog_prefix} with ${destination_blog_prefix}"
echo "sed -i 's/${source_blog_prefix}/${destination_blog_prefix}/g' wordpress_migration.sql"
sed -i "s/${source_blog_prefix}/${destination_blog_prefix}/g" wordpress_migration.sql
echo 

echo 
oc cp wordpress_migration.sql $destination_pod:/opt/app-root/src
oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages db import wordpress_migration.sql
oc exec $destination_pod -- rm wordpress_migration.sql
rm wordpress_migration.sql
echo 

#search and replace the site id in all url/settings in the site's tables.
echo 
echo "#"
echo "# Search and Replace site id and site url in the sites imported tables"
echo "#" 

echo 
echo "Search and Replace 'sites/${source_blog_id}/' with 'sites/${destination_blog_id}/ in site tables"
echo "wp search-replace sites/${source_blog_id}/ sites/${destination_blog_id}/ --all-tables-with-prefix --recurse-objects  --skip-columns=guid --skip-themes --skip-plugins --skip-packages --url=${blog_url}"
echo 
oc exec $destination_pod -- wp search-replace sites/${source_blog_id}/ sites/${destination_blog_id}/ --all-tables-with-prefix --recurse-objects  --skip-columns=guid --skip-themes --skip-plugins --skip-packages --url=${blog_url}
echo 
echo 
oc exec $destination_pod -- wp cache flush --skip-themes --skip-plugins --skip-packages 
echo 

#
# Add User Accounts
#

echo 
echo "#"
echo "# Add accounts with roles to site and updating user ids for content...."
echo "#"
while read -r source_user_id user_login source_user_roles; do

    if [[ ${source_user_id} == "ID" ]]; then
        continue
    fi
    
    echo 
    destination_user_id=$(oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages user get ${user_login} --url=${blog_url} --field=ID)
    
    if [[ ${user_login} != "atwebdev" ]]; then
      echo "Added roles to ${user_login}"
      for role in ${source_user_roles//,/ }
      do
          oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages user add-role --url=${blog_url} ${destination_user_id} ${role}
      done
    fi
    
    # Correct ids for imported content to the new id of the author.
    if [ ! -z "${author_posts[$source_user_id]}" ] 
    then
        echo 
        echo "Updating the post author id for this users posts."
        echo "UPDATE ${destination_db}.${destination_blog_prefix}posts SET post_author='${destination_user_id}' WHERE ID IN (${author_posts[$source_user_id]})"
        echo 
        oc exec $destination_pod -- wp db query "UPDATE ${destination_db}.${destination_blog_prefix}posts SET post_author='${destination_user_id}' WHERE ID IN (${author_posts[$source_user_id]})" --skip-themes --skip-plugins --skip-packages
        echo 
    fi

    if [ ! -z "${user_submissions[$source_user_id]}" ] 
    then
        echo 
        echo "Updating the submssion user id for this user ninja forms submissions."
        echo "UPDATE ${destination_db}.${destination_blog_prefix}ninja_forms_uploads SET user_id='${destination_user_id}' WHERE ID IN (${user_submissions[$source_user_id]})"
        echo 
        oc exec $destination_pod -- wp db query "UPDATE ${destination_db}.${destination_blog_prefix}ninja_forms_uploads SET user_id='${destination_user_id}' WHERE ID IN (${user_submissions[$source_user_id]})" --skip-themes --skip-plugins --skip-packages
        echo 
    fi
    
    echo       
done <<< "$user_list"
  
#
# Site activate default plugins
#

echo 
echo "#"
echo "# Activation Plugins...."
echo "#"

if [ ! -z "$blog_plugins" ]
then
    echo 
    oc exec $destination_pod -- wp plugin activate --url=${blog_url} ${blog_plugins} --skip-themes --skip-plugins --skip-packages 
    echo
fi

# THese are required to be activated so activating them again just in case
echo 
oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages plugin activate --url=${blog_url} advanced-custom-fields-pro/acf.php ecu-admin-2 envira-gallery so-widgets-bundle wp-crontrol envira-fullscreen envira-pagination envira-schedule envira-slideshow envira-zip-importer monarch vendi-tinymce-anchor ninja-forms ninja-forms-conditionals ninja-forms-excel-export ninja-forms-multi-part ninja-forms-uploads ninja-forms-style ninja-forms-save-progress ninja-forms-pdf-submissions shortcode-ui tablepress wp-localist ecu-plugins user-role-editor enable-media-replace classic-editor display-posts-shortcode safe-svg post-expirator ecu-so-widgets social-media-meta
echo

#
# Set Meta Values
#

echo
echo "#" 
echo "# Set Network Site Settings...."
echo "#"

destination_blog_upload_space=$(oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages network meta get --url=wordpressdev.ecu.edu ${destination_site_id} blog_upload_space)
destination_fileupload_maxk=$(oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages network meta get --url=wordpressdev.ecu.edu ${destination_site_id} fileupload_maxk)

if [ $source_blog_upload_space -gt $destination_blog_upload_space ]
    then
        echo 
        echo "Setting blog_upload_space to ${source_blog_upload_space}"
        echo "wp --skip-themes --skip-plugins --skip-packages network meta set --url=wordpressdev.ecu.edu ${destination_site_id} blog_upload_space ${source_blog_upload_space}"
        oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages network meta set --url=wordpressdev.ecu.edu ${destination_site_id} blog_upload_space ${source_blog_upload_space}
        echo 

fi
if [ $source_fileupload_maxk -gt $destination_fileupload_maxk ]
    then
        echo 
        echo "Setting fileupload_maxk to ${source_fileupload_maxk}"
        oc exec $destination_pod -- wp --skip-themes --skip-plugins --skip-packages network meta set --url=wordpressdev.ecu.edu ${destination_site_id} fileupload_maxk ${source_fileupload_maxk}
        echo 
fi

echo 
echo "Search and Replace production domain with dev domain"
echo "wp search-replace ${DOMAIN}.ecu.edu ${DOMAIN}dev.ecu.edu --recurse-objects --network --skip-columns=guid --skip-themes --skip-plugins --skip-packages --url=${blog_url}"
echo 
echo 
oc exec $destination_pod -- wp search-replace ${DOMAIN}.ecu.edu ${DOMAIN}dev.ecu.edu --recurse-objects --network --skip-columns=guid --skip-themes --skip-plugins --skip-packages --url=${blog_url}
echo 


#
# Flush Redis
#
echo
echo "#"
echo "# Flush Redis ...."
echo "#"
echo 
oc exec $destination_pod -- wp cache flush --skip-themes --skip-plugins --skip-packages 
echo 

#
#
# Flush Rewrites ..
#
echo 
echo "#"
echo "#Flush Rewrite ...."
echo "#"
echo 
oc exec $destination_pod -- wp rewrite flush --url=${DOMAIN}ua.ecu.edu --skip-themes --skip-plugins --skip-packages 
echo 

echo
echo "#"
echo "# Writing site ids for the SSH build step to copy files: $source_blog_id,$destination_blog_id"
echo "#"
echo
echo "$source_blog_id,$destination_blog_id" >> ssh.txt
echo 

