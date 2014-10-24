#!/bin/sh
# This file makes a backup of your MySQL databases. It will use mysqldump to 
# create a seperate file of each database in it's own folder. It will create a
# MD5 checksum file of each database to ensure it is compressed and uncompressed
# correctly. It will then tar and gzip the backups into a single timestamped
# file and then clean up after itself. It will email you if any part of the 
# script fails with which part failed and why. 
#
# YOUREMAIL:  The email address you want to send the email to if any part of
# this script fails. Multiple email addresses are supported if separated
# by a space.
YOUREMAIL="email@email.com
# SERVERNAME:  How you want your server's name to appear in the email in the
# event that the database is corrupt.
SERVERNAME=Server
# Scroll down to edit the email as you see fit.  The default setup is recommended
# since it works and conveys a simple email to let you know what the problem
# is and that you need to take action.
# If you want to test this to ensure it works, simply rename the line with
# freenas-v1.db to pointto a file that doesn't exist.  It will error, and you will get
# an email.
#
# BACKUP_DIR: A location where the backup file is to be stored. This is also used
# as tempory storage for files created in the scripts operation. 
BACKUP_DIR=/mnt/MySQLDatabase/
#
# JAILDIRONHOST: Location of where the jail is located on the host FreeBSD system.
# This is required for the mail portion. If an error occurs, the script sends a command
# to the FreeBSD host to send the mail. The script must tell the host where the file
# is located that holds the email data. 
JAILDIRONHOST="/mnt/SSDData/Jails/MySQL"
#
# HOSTFREEBSDADDR: IP address for the host FreeBSD system that will send the email. 
# Ensure that this host can send email from the CLI with the sendmail command. 
HOSTFREEBSDADDR=192.168.128.10
#
# HOSTFREEBSDUSER: User to log into the FreeBSD system with. Ensure that this user has
# SSH access and that the public/private keys are correct to that login can occur from
# this jail to the host with this user without a password. 
HOSTFREEBSDUSER=root
# MYSQL_USER: Username used to login into MySQL
MYSQL_USER="root"
#
# MYSQL_PASSWORD= Password used to login into MySQL
MYSQL_PASSWORD="password"
#
# TIMESTAMP: This is the name of the final file. 
TIMESTAMP=$(date +"%F")
# 
# VERSIONS: The age of the backups to keep. Any backups older than VERSIONS * DAYS will
# be deleted. This only works on age, so if 3 backups are made in the same day, thay
# will all be kept and deleted together. Old files are only deleted if the whole script
# runs successfully. If any one part fails, then no old files will be deleted for recovery
# reasons. Default: 120 (4 months)
VERSIONS=120
#
# These are used in the operation of the script. Do not touch these. 
ERRORFILE=${BACKUP_DIR}stderr2.txt
PASSVAR=0
PASSVAR2=0

# Remove temp files possibly left over from a failed previous run.
if [ -f "$BACKUP_DIR"/badconfig.txt ]; then 
	rm "$BACKUP_DIR"/badconfig.txt
fi
if [ -f "$ERRORFILE" ]; then
	rm "$ERRORFILE"
fi

# Set up the header of a failed email. Do this now so we can add to it at certain
# stages of the script that may file. Complete as it works through the script and
# email at the end. 
echo ""
echo "To: $YOUREMAIL" >> $BACKUP_DIR/badconfig.txt
echo "Subject: ERROR: Backup of MySQL database on $SERVERNAME." >> $BACKUP_DIR/badconfig.txt
echo "" >> $BACKUP_DIR/badconfig.txt
echo "Your server, $SERVERNAME, has been unsuccessful in backing up the MySQL database." >> $BACKUP_DIR/badconfig.txt
echo " " >> $BACKUP_DIR/badconfig.txt
echo "It is recommended you troubleshoot and correct the problem as soon as possible.  Your database is no longer safe from corruption." >> $BACKUP_DIR/badconfig.txt
echo "" >> $BACKUP_DIR/badconfig.txt

# Query MySQL for the names of the individual databases requiring backing up. 
DATABASES=`mysql --user=${MYSQL_USER} -p${MYSQL_PASSWORD} -e "SHOW DATABASES;" 2> ${ERRORFILE} | grep -Ev "(Database|information_schema|performance_schema)"` 

# If able to successfully read database information from MySQL then create folder
# for temporary files. 
if [ "$?" -eq 0 ]; then
	echo "Successfully read databases from MySQL on $SERVERNAME!"
	# Check if the file already exists, may happen if script run more than
	# once in the same day	
	if [ -e ${BACKUP_DIR}${TIMESTAMP}.tgz ]; then
		echo "Backup file ${TIMESTAMP}.tgz already exists...adding time"
		echo "New backup file will be: "$(date +"%F_%H%M%S%Z")".tgz"
		# If it exists, change the folder name to include the time. 		
		TIMESTAMP=$(date +"%F_%H%M%S%Z")
		mkdir ${BACKUP_DIR}${TIMESTAMP}
	else 
		echo "Backup file will be called: "${TIMESTAMP}".tgz"
		mkdir ${BACKUP_DIR}${TIMESTAMP}
	fi
else
	# If unable to read databases from MySQL, then add to email report it. 
	echo "Failed to read databases from MySQL on $SERVERNAME!"
	echo "Failed to read databases from MySQL on $SERVERNAME!" >> $BACKUP_DIR/badconfig.txt
	echo "The reported error message from MySQL is:" >> $BACKUP_DIR/badconfig.txt
	VAR=`sed -n '1p' ${ERRORFILE}`
	echo "$VAR" >> $BACKUP_DIR/badconfig.txt
	PASSVAR=1
fi

echo ""

# Time to read the databases from MySQL and dump them to their own .sql file. 
for db in $DATABASES; do
	# Create a individual folder for each database. 
	mkdir ${BACKUP_DIR}${TIMESTAMP}/${db}
	# Read the database and write to .sql file. 
	mysqldump --opt --user=${MYSQL_USER} --password=${MYSQL_PASSWORD} --databases ${db} > ${BACKUP_DIR}${TIMESTAMP}/${db}/${db}.sql 2> ${ERRORFILE}
    
	# Check if the .sql file was created successfully. 
	if [ "$?" -eq 0 ]; then
		# If it was, do this. 
		echo "Database ${db} copy is ok."
		# Read the MD5 checksum of the .sql file and write it to its own
		# .md5 file, stored in the same folder of the .sql file. 
		md5 -q ${BACKUP_DIR}${TIMESTAMP}/${db}/${db}.sql > ${BACKUP_DIR}${TIMESTAMP}/${db}/${db}.md5
	else
		# If the .sql file was not created successfully, add reasons to email
		# and report it. 
		echo "Backup of database ${db} failed!" 
		echo "Database $db failed!" >> $BACKUP_DIR/badconfig.txt
		echo "The reported error message from mysqldump is:" >> $BACKUP_DIR/badconfig.txt
		VAR=`sed -n '1p' ${ERRORFILE}`
		echo "$VAR" >> $BACKUP_DIR/badconfig.txt
		echo " " >> $BACKUP_DIR/badconfig.txt
		# Remove any temp files created for the failed database dump. 
		rm -r ${BACKUP_DIR}${TIMESTAMP}/${db}
		# Check if the temp folder is empty. If not, it may be that at least one
		# database was successful, even though this one failed. In that case, 
		# allow script to continue, but warn about failed database. 
		if [ "$(ls -A ${BACKUP_DIR}${TIMESTAMP})" ]; then
			# Action to take if temp folder is not empty.		
			PASSVAR=0
			# Continue, but still send email with at least one database filed. 
			PASSVAR2=1
		else
			# Action to take if temp folder is empty.
			PASSVAR=1
		fi
	fi
done

echo ""

# This if statements checks if a previous command has failed. 
if [ "$PASSVAR" != 1 ]; then
	# If everything is good so far, continue on compressing the .sql and .md5 files
	# into a single .tgz file. 
	echo ""
	printf "Moving all databases into single file..."
	cd ${BACKUP_DIR}${TIMESTAMP}/
	tar cfvz ${BACKUP_DIR}${TIMESTAMP}.tgz * 2> ${ERRORFILE}
	# Check if the .tgz file was created successfully. 
	if [ "$?" -eq 0 ]; then
		# If yes, the clean up now unnecessary files. 
		printf "\rMoving all databases into single file...successful\n"
		echo ""
		printf "Cleaning up..."
		rm -r ${BACKUP_DIR}${TIMESTAMP}
		rm ${ERRORFILE}
		if [ ${PASSVAR2} != 1 ]; then 
			rm "$BACKUP_DIR"/badconfig.txt
		fi
		# Only keep the specified number of backups older than the 
		# VERSIONS variable
		DELETEDFILES=`find ${BACKUP_DIR} -type f -mtime +${VERSIONS} -maxdepth +1 -name "*.tgz" | awk -F/ '{ print $NF }'`
		if [ "${DELETEDFILES}" != "" ]; then
			`find ${BACKUP_DIR} -type f -mtime +${VERSIONS} -maxdepth +1 -name "*.tgz" -delete`
			printf "\rCleaning up...done\n"			
			echo "Deleted files:" $DELETEDFILES
		else
			printf "\rCleaning up...done\n"			
			echo "No backups older than ${VERSIONS} days to delete."
		fi
	else
		# If not, then add to email file and report it. Then remove the
		# file created so far. Leaving them would create unnecessary 
		# clutter in the backup dir. The matter is reported. 		
		echo "Creation of ${TIMESTAMP}.tgz failed!"
		echo ""
		echo "Creation of ${TIMESTAMP}.tgz not successful!" >> $BACKUP_DIR/badconfig.txt
		echo "The reported error message from tar is:" >> $BACKUP_DIR/badconfig.txt
		VAR=`sed -n '1p' ${ERRORFILE}`
		echo "$VAR" >> $BACKUP_DIR/badconfig.txt
		PASSVAR=1
		rm -r ${BACKUP_DIR}${TIMESTAMP}
		rm ${ERRORFILE}
	fi
elif [ "$PASSVAR" = 1 ] || [ "$PASSVAR2" = 1 ]; then
	# What to do if any command in the script has reported a failure. Email away the
	# final file and then remove temporary files. 
 	SENDMAILCOMMAND=" sendmail -t < ${JAILDIRONHOST}${BACKUP_DIR}badconfig.txt"
	printf "Sending email..."
	ssh ${HOSTFREEBSDUSER}@${HOSTFREEBSDADDR} ${SENDMAILCOMMAND}
	printf "\rSending email...done\n"
	rm "$BACKUP_DIR"/badconfig.txt
	rm ${ERRORFILE}
	rm -r ${BACKUP_DIR}${TIMESTAMP}
	echo "Failed!!!!"
fi

# EOF
