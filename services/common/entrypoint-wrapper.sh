#!/bin/bash

CURRENT_ADMIN_ROLE_NAME="cassandra"
CURRENT_ADMIN_ROLE_PASSWORD="cassandra"

ALTER_ROLE_DDL="ALTER ROLE"
CREATE_ROLE_DDL="CREATE ROLE IF NOT EXISTS"

RETRY_SLEEP_TIME=30


info() {
    echo "INFO  [entrypoint] $1"
}

execute_cql_statement() {
    # 1 - CQL statement
    local  input_opt=""
    if [ -f "$1" ]
    then
        input_opt="f"
    else
        input_opt="e"
    fi

    cqlsh localhost -u "$CURRENT_ADMIN_ROLE_NAME" -p "$CURRENT_ADMIN_ROLE_PASSWORD" "-${input_opt}" "$1"
}

execute_cql_statement_suppress_stderr() {
    execute_cql_statement "$1" 2>/dev/null
}

assemble_role_statement() {
    # 1 - action
    # 2 - user name
    # 3 - user password
    # 4 - is superuser
    # 5 - is login enabled
    local cql_role_statement="$1 $2 WITH PASSWORD = '$3' AND SUPERUSER = $4 AND LOGIN = $5;"
    execute_cql_statement "$cql_role_statement"
}

alter_role() {
    info "Altering user '$1' with superuser=$3 and login=$4"
    # 1 - user name
    # 2 - user password
    # 3 - is superuser
    # 4 - is login enabled
    assemble_role_statement "$ALTER_ROLE_DDL" "$1" "$2" "$3" "$4"
}

create_role() {
    info "Creating user '$1' with superuser=$3 and login=$4"
    # 1 - new user name
    # 2 - new user password
    # 3 - is superuser
    # 4 - is login enabled
    assemble_role_statement "$CREATE_ROLE_DDL" "$1" "$2" "$3" "$4"
}

grant_user_permission() {
    info "Granting user '$1' with permissions $2 for resource $3"
    # 1 - user name
    # 2 - permissions
    # 3 - resource
    execute_cql_statement "GRANT $2 ON $3 TO $1;"
}

replace_super_user() {
    # 1 - new admin name
    # 2 - new admin password
    local old_admin_name="$CURRENT_ADMIN_ROLE_NAME"
    local old_admin_password="$CURRENT_ADMIN_ROLE_PASSWORD"
    local new_admin_name="$1"
    local new_admin_password="$2"

    info "Replacing '$old_admin_name' user with '$new_admin_name'"
    create_role "$new_admin_name" "$new_admin_password" "true" "true"
    CURRENT_ADMIN_ROLE_NAME="$new_admin_name"
    CURRENT_ADMIN_ROLE_PASSWORD="$new_admin_password"
    alter_role "$old_admin_name" "$old_admin_password" "false" "false"
}

create_schema() {
    info "Applying schema"
    execute_cql_statement "$SCHEMA_CQL"
    execute_cql_statement "DESCRIBE SCHEMA;"
}

insert_test_data() {
    info "Inserting test data"
    execute_cql_statement "$TEST_DATA_CQL"
    nodetool flush
}

post_start_operations() {
    # Wait for CQLSH to be available before we perform operations on the user accounts

    while ! execute_cql_statement_suppress_stderr "quit;"
    do
        info "No RPC interface unavailable; waiting $RETRY_SLEEP_TIME seconds before trying again"
        sleep $RETRY_SLEEP_TIME
    done

    create_schema

    if [ -n "$TEST_DATA_CQL" ]
    then
        insert_test_data
    fi

    if [ -n "$ADMIN_ROLE_NAME" ] && [ -n "$ADMIN_ROLE_PASSWORD" ]
    then
        replace_super_user "$ADMIN_ROLE_NAME" "$ADMIN_ROLE_PASSWORD"
    fi

    info "Post start operations complete!"
}

set_operating_file_values() {
    local file_path="$1"
    local env_var_prefix="$2"
    local delimiter="$3"
    local add_space_after_delimiter="$4"

    cassandra_env_config_values=("$(env | grep "$env_var_prefix" || echo '')")

    if [ "${#cassandra_env_config_values[@]}" -eq 0 ]
    then
        return 0
    fi

    info "Updating settings in $file_path"
    for env_var in ${cassandra_env_config_values[*]}
    do
        conf_key=$(cut -d'=' -f1 <<<"${env_var/$env_var_prefix/}" | tr '[:upper:]' '[:lower:]')
        new_conf_val="${env_var/*=/}"

        temp_conf_val=""
        if [ "${new_conf_val:0:4}" = "env:" ]
        then
            eval "temp_conf_val=\$$(cut -d':' -f2 <<<"$new_conf_val")"
            new_conf_val="$temp_conf_val"
        fi

        # Get the line from the file that contains the conf_key as we need it to determine if it starts with a '#'
        conf_line=$(grep -e "^[\ #\-]*${conf_key}${delimiter}" "$file_path")
        old_conf_val=$(tr -d ' ' <<<"$conf_line" | cut -d"${delimiter}" -f2)

        if [ "$old_conf_val" != "$new_conf_val" ] || grep -q "#" <<<"$conf_line"
        then
            info " - Setting ${conf_key}${delimiter}${add_space_after_delimiter}${new_conf_val}"
            if [ "${conf_line:0:1}" = "#" ] && [ "${conf_line:2:1}" != " " ]
            then
                sed -i -E "s,^#[\ ]?${conf_key}${delimiter}.*,${conf_key}${delimiter}${add_space_after_delimiter}${new_conf_val},g" "$file_path"
            else
                # Preserve the space before the '#' if it exists, and subsequent spaces following the first space after
                # the '#' as well. For example, we want to set resolve_multiple_ip_addresses_per_dns_record to true:
                # >      - seeds: "127.0.0.1:7000"
                # >      #  resolve_multiple_ip_addresses_per_dns_record: false
                # becomes
                # >      - seeds: "127.0.0.1:7000"
                # >        resolve_multiple_ip_addresses_per_dns_record: true
                sed -i -E "s,^([\ ]*)[#]?([\ ]*)([\-]?[\ ]*${conf_key})${delimiter}.*,\1\2\3${delimiter}${add_space_after_delimiter}${new_conf_val},g" "$file_path"
            fi
        fi
    done
}

#--- main execution ----------------------------------------------------------------------------------------------------

. /base-checks.sh

set_operating_file_values "$CASSANDRA_YAML" "CASSANDRA_YAML_" ":" " "
set_operating_file_values "$CASSANDRA_RACKDC_PROPERTIES" "CASSANDRA_RACKDC_PROPERTIES_" "=" ""

sleep 5
post_start_operations &

exec "dse" "cassandra" "-f"