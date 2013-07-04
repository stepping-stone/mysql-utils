#!/bin/bash
################################################################################
# mysql-backup.sh - Dumps and compresses all MySQL databases
################################################################################
#
# Copyright (C) 2013 stepping stone GmbH
#                    Bern, Switzerland
#                    http://www.stepping-stone.ch
#                    support@stepping-stone.ch
#
# Authors:
#   Christian Affolter <christian.affolter@stepping-stone.ch>
#
# Licensed under the EUPL, Version 1.1.
#
# You may not use this work except in compliance with the
# Licence.
# You may obtain a copy of the Licence at:
#
# http://www.osor.eu/eupl
#
# Unless required by applicable law or agreed to in
# writing, software distributed under the Licence is
# distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied.
# See the Licence for the specific language governing
# permissions and limitations under the Licence.
#
# This script dumps and compresses each MySQL database separatly to a
# backup directory. It creates a dump in the form <DATABASE NAME>.YYYYMMDD.bz2
# Finally it delets dumps which are older than 14 days (or DELETE_AFTER)
#
# Include this script in a daily cronjob.
#
# It is assumed that the script will be started from a user with the MySQL
# credentials within its local MySQL options file (~/.my.cnf).
# Otherwise the MYSQL_CMD and MYSQLDUMP_CMD can be exported with the -u and -p
# set.
################################################################################

# The path to the lib directory.
# The default value only works if not sourced or executed from within $PATH
LIB_DIR=${LIB_DIR:="$(readlink -f ${0%/*})/../share/stepping-stone/lib/bash"}

source "${LIB_DIR}/input-output.lib.sh"
source "${LIB_DIR}/syslog.lib.sh"


MYSQL_CMD=${MYSQL_CMD:='/usr/bin/mysql'}
MYSQLDUMP_CMD=${MYSQLDUMP_CMD:='/usr/bin/mysqldump'}
MYSQLDUMP_OPTS=${MYSQLDUMP_OPTS:='--flush-logs'}

FIND_CMD=${FIND_CMD:='/usr/bin/find'}
DELETE_AFTER=${DELETE_AFTER:=14}  # delete backup after # of days

GREP_CMD=${GREP_CMD:='/bin/grep'}

DATE_CMD=${DATE_CMD:='/bin/date'}
DATE_FORMAT=${DATE_FORMAT:='%Y%m%d'}

COMPRESSOR_CMD=${COMPRESSOR_CMD:='/bin/bzip2'}
COMPRESSOR_OPTS=${COMPRESSOR_OPTS:='--best --force --quiet'}
COMPRESSOR_SUFFIX=${COMPRESSOR_SUFFIX:='bz2'}

MYSQLDUMP_DIR=${MYSQLDUMP_DIR:='/var/backup/mysql/dump'}

UMASK=${UMASK:='077'}

# Returns the MySQL server version
function getMySQLVersion()
{
    # clear the PIPESTATUS, to make sure it contains no values beforhand
    unset PIPESTATUS

    # Get the MySQL version, in the form of X.Y.Z
    echo "SELECT version();" | ${MYSQL_CMD} | ${GREP_CMD} -o -P "\d+\.\d+\.\d+"

    # If one of the piped commands faild, consider it as an error
    local returnCode
    for returnCode in "${PIPESTATUS[@]}"; do
        if [ $returnCode -ne 0 ]; then
            return $returnCode
        fi
    done

    return 0
}



# Returns all database names which are present on this server
function getAllDatabases ()
{
    # clear the PIPESTATUS, to make sure it contains no values beforhand
    unset PIPESTATUS


    # list all databases but exclude information_schema and performance_schema
    echo "SHOW DATABASES" | ${MYSQL_CMD} --column-names=0 | \
        $GREP_CMD -v -E '^information_schema|performance_schema$'

    # If one of the piped commands faild, consider it as an error
    local returnCode
    for returnCode in "${PIPESTATUS[@]}"; do
        if [ $returnCode -ne 0 ]; then
            return $returnCode
        fi
    done

    return 0
}


# Dumps and compresses a database
function dumpDatabase ()
{
    local database="$1"

    local today=$( ${DATE_CMD} +${DATE_FORMAT}  )

    local dumpTarget="${MYSQLDUMP_DIR}/${database}.${today}.${COMPRESSOR_SUFFIX}"

    local consistencyHandling='--single-transaction'

    # If a database uses non transactional table storage engines
    # we have to lock the table before dumping and can't use transactions
    # see http://dev.mysql.com/doc/refman/5.5/en/mysqldump.html#option_mysqldump_lock-tables
    if databaseHasNonTransactionalStorageEngine "$database"; then
        consistencyHandling='--lock-tables'
    fi

    # clear the PIPESTATUS, to make sure it contains no values beforhand
    unset PIPESTATUS

    ${MYSQLDUMP_CMD} ${MYSQLDUMP_OPTS} ${consistencyHandling} ${database} | \
        ${COMPRESSOR_CMD} ${COMPRESSOR_OPTS} > ${dumpTarget}

    # if either mysqldump (before the pipe) or the compressor (after the pipe)
    # faild, consider it as an error
    if [ ${PIPESTATUS[0]} -ne 0 -o ${PIPESTATUS[1]} -ne 0 ]; then
        return 1
    fi

    return 0
}


# Check if a table of a given database uses a non transactional
# storage engine such as MyISAM.
#    
# Returns 0 if at least one table uses a non transactional storage engine
function databaseHasNonTransactionalStorageEngine
{
    local database="$1"
    
    local sql="SELECT COUNT(ENGINE) FROM TABLES 
               WHERE TABLE_SCHEMA='${database}' AND NOT ENGINE='InnoDB';"
    
    local cmd="echo \"$sql\" | ${MYSQL_CMD} --column-names=0 INFORMATION_SCHEMA"

    local numberOfTables=$( eval $cmd )


    # error in MySQL command
    if [ $? -ne 0 ]; then
        return 2
    fi

    # At least one table uses a non transactional storage engine
    if [ $numberOfTables -gt 0 ]; then
        return 0
    fi

    # All tables uses transactional storage engines
    return 1
}


function doMySQLBackup ()
{
    umask ${UMASK}

    local database=''
   
    info 'Starting MySQL backup'   

    if [ ! -d "${MYSQLDUMP_DIR}" ]; then
        die "Missing dump dir '${MYSQLDUMP_DIR}', unable to proceed"
    elif [ ! -w "${MYSQLDUMP_DIR}" ]; then
        die "Dump dir '${MYSQLDUMP_DIR}' is not writable, unable to proceed"
    fi
    
    # Check if the MySQL version is new enough to include the --events option
    local mysqlVersion=$( getMySQLVersion )

    if [ -z ${mysqlVersion} -o $? -ne 0 ]; then
        error "Could not determine the MySQL server version"
    elif [[ "${mysqlVersion}" < "5.1.6" ]]; then
        info "MySQL server version is too old to add the --events option"
    else
        MYSQLDUMP_OPTS="${MYSQLDUMP_OPTS} --events"
    fi


    # clear the PIPESTATUS, to make sure it contains no values beforhand
    unset PIPESTATUS

    getAllDatabases | while read database; do
        info "Dumping database '${database}'"
        if ! dumpDatabase "$database"; then
            error "Error while dumping database '${database}'"
        else
            info "Database '${database}' successfully dumped"
        fi
    done

    # Check if the mysql command (within getAllDatabases) before the pipe
    # had errors
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        die "Unable to get databases"
    fi

    # delete old dumps
    ${FIND_CMD} ${MYSQLDUMP_DIR} -type f -ctime +${DELETE_AFTER} -delete

    info 'MySQL backup finished'
}


# Aaaaand here we go!
doMySQLBackup
