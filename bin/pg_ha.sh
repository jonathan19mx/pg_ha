#!/bin/sh

# Define the remote node
REMOTE=box1

# Postgres user
PGUSER=pgsql

# Contact 
CONTACT="John Doe <jdoe@foobar.com>"

# Date
TIME=$(date +%Y-%m-%d_%H:%M)

# Since this script may launches at boot, we need to set the proper path.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/games:/usr/local/sbin:/usr/local/bin

if [ "$1" == "" ];
	then
		echo "Usage: pg_ha.sh status|master|slave|init-slave"
	fi

case "$1" in

	master)
		# This is the trigger for PostgreSQL to step up as master
		sudo -u $PGUSER touch /tmp/pgsql.trigger
		echo -e "$(hostname) was just promoted to master for PostgreSQL.\n\nMake sure to login and active the slave." | mail -s "Warning! $(hostname) is now the PostgreSQL Master" $CONTACT
	;;
	
	slave)
		echo "Taking backup of local files prior to overwriting data."
		sudo -u $PGUSER mkdir -p /usr/local/pgsql/ha_backups
		sudo -u $PGUSER tar cfz /usr/local/pgsql/ha_backups/local_dump-$TIME.tar.gz --exclude="*~" /usr/local/pgsql/data

		echo "Removing trigger file."
		sudo -u $PGUSER rm -f /tmp/pgsql.trigger

		echo "Restarting PGSQL in stand-alone mode."
		sudo -u $PGUSER pg_ctl stop -D /usr/local/pgsql/data/ -m fast
		sudo -u $PGUSER rm -f /usr/local/pgsql/data/recovery.conf
		sudo -u $PGUSER pg_ctl start -D /usr/local/pgsql/data/

		# Dumping and restoring the database from the remote server locally.
		# If the dump fails, (ie. not exit with error code 0), we abort.
		echo "Dumping database from $REMOTE ..."
		sudo -u $PGUSER pg_dumpall -h$REMOTE -f /usr/local/pgsql/ha_backups/master_db.dump-$TIME.sql;
		if [ $? = 0 ]
			then
				echo "Restoring database..."
				sudo -u $PGUSER psql -U$PGUSER postgres -l -f /usr/local/pgsql/ha_backups/master_db.dump-$TIME.sql
				sudo -u $PGUSER cp -f /usr/local/pgsql/data/recovery.bak  /usr/local/pgsql/data/recovery.conf

				echo "Restarting PGSQL in slave-mode..."
				sudo -u $PGUSER pg_ctl stop -D /usr/local/pgsql/data/
				sudo -u $PGUSER pg_ctl start -D /usr/local/pgsql/data/ 

				echo "Compressing database-dump.."
				sudo -u $PGUSER gzip /usr/local/pgsql/ha_backups/master_db.dump-$TIME.sql
				echo -e "$(hostname) is now an active slave for PostgreSQL.\nBackups are stored in '/usr/local/pgsql/ha_backups'." | mail -s "$(hostname) is now the PostgreSQL Slave" $CONTACT
			else
				echo "Aborting. Recovery from master failed."
			fi
	;;

	init-slave)
		echo "Taking backup of local files prior to overwriting."
		sudo -u $PGUSER mkdir -p /usr/local/pgsql/ha_backups
		sudo -u $PGUSER tar cfz /usr/local/pgsql/ha_backups/local_dump-$TIME.tar.gz --exclude="*~" /usr/local/pgsql/data

		echo "Removing trigger-file"
		sudo -u $PGUSER rm -f /tmp/pgsql.trigger

		echo "Stopping PGSQL.."
		sudo -u $PGUSER pg_ctl stop -D /usr/local/pgsql/data/ -m fast

		# We'll do two sets of rsync. The first one without putting the master in backup-mode
		# and the second with the master in backup-mode. This is to minimize the downtime
		# as much as possible. We also run the first rsync with the '---checksum' and '--delete'.
		# We have to use '--delete' to remove unused files, and '--checksum' since the regular
		# rsync algorithm partially uses the timestamp to determine what needs to be synced. 

		echo "Syncing files from master to slave...(initial)"
		sudo -u $PGUSER rsync -a $PGUSER@$REMOTE:/usr/local/pgsql/data/ /usr/local/pgsql/data --checksum --delete --exclude 'postmaster.pid' --exclude '*~' --exclude '*.conf' --exclude 'recovery.*'

		echo "Putting remote master-node in backup-mode..."
		sudo -u $PGUSER psql -h$REMOTE postgres -c "SELECT pg_start_backup('restore-slave', true)" $PGUSER

		echo "Syncing files from master to slave...(final)"
		sudo -u $PGUSER rsync -a $PGUSER@$REMOTE:/usr/local/pgsql/data/ /usr/local/pgsql/data --exclude 'postmaster.pid' --exclude '*~' --exclude '*.conf' --exclude 'recovery.*'

		echo "Restoring master to regular state..."
		sudo -u $PGUSER psql -h$REMOTE postgres -c "SELECT pg_stop_backup()" $PGUSER
		sudo -u $PGUSER rm -f /usr/local/pgsql/data/recovery.done 
		sudo -u $PGUSER cp -f /usr/local/pgsql/data/recovery.bak /usr/local/pgsql/data/recovery.conf

		echo "Starting PGSQL locally..."
		sudo -u $PGUSER pg_ctl start -D /usr/local/pgsql/data/
	;;
	
	status)
		# Load variables from rc.conf
		. /etc/rc.subr
		load_rc_config ucarp

		UCARPIF=$(ifconfig | grep "$ucarp_addr " | grep -v grep)
		
		echo "Checking UCARP Status..."
		if [ "$UCARPIF" != "" ];
		then 
			# Get xlog data from PostgreSQL
			LOCALMASTERSTAT=$(sudo -u $PGUSER psql postgres -c "SELECT pg_current_xlog_location()" $PGUSER | head -n 3 | tail -n 1)
			REMOTESLAVESTAT=$(sudo -u $PGUSER psql -h$REMOTE postgres -c "SELECT pg_last_xlog_receive_location()" $PGUSER | head -n 3 | tail -n 1)
			
			echo -e "\tI'm the UCARP master!"
			echo "Checking for WAL Sender Process..."

			# Check for Wal sending process
			WALSEND=$(ps aux | grep "wal sender process" | grep -v grep)
			if [ "$WALSEND" != "" ];
			then 
				echo -e "\tWAL Sender Process found!"

				# Print Replication status
				echo -e "Master xlog location (local):"
				echo -e "\t$LOCALMASTERSTAT"
				echo -e "Slave xlog location (remote):"
				echo -e "\t$REMOTESLAVESTAT"
			else
				echo -e "\tWarning! No WAL Sender Process found."
			fi
		else
			# Get xlog data from PostgreSQL
			LOCALSLAVESTAT=$(sudo -u $PGUSER psql postgres -c "SELECT pg_last_xlog_receive_location()" $PGUSER | head -n 3 | tail -n 1)
			REMOTEMASTERSTAT=$(sudo -u $PGUSER psql -h$REMOTE postgres -c "SELECT pg_current_xlog_location()" $PGUSER | head -n 3 | tail -n 1)
			
			echo -e "\tI'm the UCARP slave!"
			echo "Checking for WAL Receiver Process..."

			# Check for Wal receiver process
			WALRECV=$(ps aux | grep "wal receiver process" | grep -v grep)
			if [ "$WALRECV" != "" ];
			then 
				echo -e "\tWAL Receiver Process found!"

				# Print Replication status
				echo -e "Slave xlog location (local):"
				echo -e "\t$LOCALSLAVESTAT"
				echo -e "Master xlog location (remote):"
				echo -e "\t$REMOTEMASTERSTAT"
			else
				echo -e "\tWarning! No WAL Receiver Process found."
			fi
		fi
	;;
esac