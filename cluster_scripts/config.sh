
# User used for all cluster admin actions
export ADMIN_USER=postgres

# Primary catalog
export PRIMARY_CATALOG_HOST=localhost
export PRIMARY_CATALOG_PORT=5432
export PRIMARY_CATALOG_DATABASE=kv_master
export PRIMARY_CATLOG_CONN=`printf 'postgresql://%s:%s/%s?user=%s'              \
                                    $PRIMARY_CATALOG_HOST $PRIMARY_CATALOG_PORT \
				    $PRIMARY_CATALOG_DATABASE $ADMIN_USER`

# Dev only settings
export RECREATE_EXISITING_NODES=true
